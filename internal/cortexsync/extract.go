package cortexsync

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/liliang-cn/cortexdb/v2/pkg/cortexdb"
	"github.com/liliang-cn/noted/internal/store"
)

// What a note's words are about, found by a language model, so two notes
// about the same thing meet in the graph. Extraction is cached per note by a
// hash of its title and content (store.CortexExtractions) and runs a few
// notes at a time; a note the model could not read keeps its earlier result.

// Entity types the model may use; each becomes the node type noted_topic_<type>.
var EntityTypes = []string{"person", "organization", "technology", "product", "place", "concept", "event"}

const (
	maxEntities      = 15
	maxAliases       = 5
	maxRelations     = 30
	maxEntityName    = 80
	minExtractRunes  = 12 // a note shorter than this has nothing worth reading
	maxSlugBytes     = 80
	defaultPerRun    = 30
	stopAfterFailing = 3 // consecutive failures that end a run's extraction
)

// ExtractionPrompt asks for the things a note talks about. cortexsync cleans and
// validates what comes back; the prompt only has to get close.
const ExtractionPrompt = `Read this note and list the named things it clearly talks about, and how they relate. Output ONLY a JSON object, no commentary:
{"entities": [{"name": "...", "type": "person|organization|technology|product|place|concept|event", "aliases": ["..."]}],
 "relations": [{"from": "entity name", "to": "entity name", "type": "snake_case_verb"}]}
Rules:
- Only entities clearly present in the text. 0 to 15 per note. A note with nothing worth naming returns {"entities": [], "relations": []}.
- Keep every name in the language the note uses it in; do not translate. "aliases" are other spellings of the same entity that appear in the note (abbreviation, nickname); usually empty.
- type is exactly one of: person, organization, technology, product, place, concept, event. person is a human being only: a software, tool or service name is technology or product, a machine or city is place.
- Leave out generic words (meeting, plan, problem), dates, times, numbers, prices and the author themself.
- A relation joins two entities from your own list, using their exact names. type is a short snake_case verb phrase such as uses, depends_on, part_of, works_at, located_in, compares_with, replaces, runs_on. Only relations the text states.`

// MaxExtractText is how many runes of a note a reader is given.
const MaxExtractText = 6000

// Entity is something a note names.
type Entity struct {
	Name    string   `json:"name"`
	Type    string   `json:"type"`
	Aliases []string `json:"aliases,omitempty"`
}

// Relation says how two entities of one note relate; From and To are entity names.
type Relation struct {
	From string `json:"from"`
	To   string `json:"to"`
	Type string `json:"type"`
}

// Extraction is what one note says about the world.
type Extraction struct {
	Entities  []Entity   `json:"entities"`
	Relations []Relation `json:"relations"`
}

// Extractor reads a note's text.
type Extractor interface {
	Extract(ctx context.Context, title, content string) (Extraction, error)
}

// Raw adapts a function that returns the model's raw answer, such as
// (*ai.Agent).EntitiesJSON, to an Extractor that parses and cleans it.
type Raw func(ctx context.Context, title, content string) (string, error)

func (f Raw) Extract(ctx context.Context, title, content string) (Extraction, error) {
	out, err := f(ctx, title, content)
	if err != nil {
		return Extraction{}, err
	}
	return ParseExtraction(out)
}

// TextHash is what tells whether a note changed since it was read.
func TextHash(title, content string) string {
	sum := sha256.Sum256([]byte(title + "\x00" + content))
	return hex.EncodeToString(sum[:16])
}

// ParseExtraction reads the model's answer: the first JSON object in it,
// cleaned.
func ParseExtraction(out string) (Extraction, error) {
	i, j := strings.Index(out, "{"), strings.LastIndex(out, "}")
	if i < 0 || j < i {
		return Extraction{}, fmt.Errorf("the model did not return JSON: %.80q", out)
	}
	var x Extraction
	if err := json.Unmarshal([]byte(out[i:j+1]), &x); err != nil {
		return Extraction{}, fmt.Errorf("the model returned malformed JSON: %w", err)
	}
	return Clean(x), nil
}

// Clean keeps the entities worth a node and the relations between them:
// names trimmed; duplicates (ignoring case) and one-character names, unknown
// types and long names dropped; at most 15 entities; relations only between
// kept entities (named by an alias counts), with a snake_case type.
func Clean(x Extraction) Extraction {
	var out Extraction
	byName := map[string]string{} // lower-cased name or alias -> canonical name
	for _, e := range x.Entities {
		name := strings.TrimSpace(e.Name)
		typ := strings.ToLower(strings.TrimSpace(e.Type))
		n := utf8.RuneCountInString(name)
		if n < 2 || n > maxEntityName || !validType(typ) {
			continue
		}
		if _, dup := byName[strings.ToLower(name)]; dup {
			continue
		}
		byName[strings.ToLower(name)] = name
		ne := Entity{Name: name, Type: typ}
		seen := map[string]bool{strings.ToLower(name): true}
		for _, a := range e.Aliases {
			a = strings.TrimSpace(a)
			la := strings.ToLower(a)
			if utf8.RuneCountInString(a) < 2 || utf8.RuneCountInString(a) > maxEntityName || seen[la] || len(ne.Aliases) == maxAliases {
				continue
			}
			seen[la] = true
			ne.Aliases = append(ne.Aliases, a)
		}
		out.Entities = append(out.Entities, ne)
		if len(out.Entities) == maxEntities {
			break
		}
	}
	// Aliases resolve a relation's end; a name an entity already has wins.
	for _, e := range out.Entities {
		for _, a := range e.Aliases {
			if _, taken := byName[strings.ToLower(a)]; !taken {
				byName[strings.ToLower(a)] = e.Name
			}
		}
	}
	seen := map[string]bool{}
	for _, r := range x.Relations {
		from, ok1 := byName[strings.ToLower(strings.TrimSpace(r.From))]
		to, ok2 := byName[strings.ToLower(strings.TrimSpace(r.To))]
		typ := snake(r.Type)
		k := from + "\x00" + to + "\x00" + typ
		if !ok1 || !ok2 || from == to || typ == "" || seen[k] {
			continue
		}
		seen[k] = true
		out.Relations = append(out.Relations, Relation{From: from, To: to, Type: typ})
		if len(out.Relations) == maxRelations {
			break
		}
	}
	return out
}

func validType(t string) bool {
	for _, v := range EntityTypes {
		if v == t {
			return true
		}
	}
	return false
}

// snake turns a relation type into lower_snake_case. "mentions" is the name
// CortexDB keeps for its own chunk edges, so it becomes related_to.
func snake(s string) string {
	var b strings.Builder
	under := true
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			under = false
		} else if !under {
			b.WriteByte('_')
			under = true
		}
	}
	out := strings.Trim(b.String(), "_")
	if utf8.RuneCountInString(out) > 40 {
		out = strings.Trim(string([]rune(out)[:40]), "_")
	}
	if out == "mentions" {
		return "related_to"
	}
	return out
}

// slug is the stable part of a topic node id: the name lower-cased with runs
// of whitespace (and colons, which separate id parts) as one dash; a very
// long name is replaced by its hash.
func slug(name string) string {
	s := strings.Join(strings.Fields(strings.ToLower(strings.ReplaceAll(name, ":", " "))), "-")
	if len(s) > maxSlugBytes {
		sum := sha256.Sum256([]byte(s))
		return "h" + hex.EncodeToString(sum[:12])
	}
	return s
}

// TopicID is the graph node id of an entity: one per user, type and name, so
// every note that names it points at the same node.
func TopicID(user, typ, name string) string {
	return cortexdb.EntityNodeIDPrefix + "noted:" + user + ":topic:" + typ + ":" + slug(name)
}

// topics adds a note's extracted entities to its record: an "about" edge to
// each, the relations between them, and the line of names for its text. A
// person who is one of the user's people is linked to as that person (an
// "about" relation among rels, which also carries their entity to the brain)
// instead of getting a topic node.
func (b *builder) topics(noteID, noteKey string, rels *[]rel) (extra []cortexdb.ToolEntityInput, extraRel []cortexdb.ToolRelationInput, names string) {
	x, ok := b.s.Extractions[noteID]
	if !ok || len(x.Entities) == 0 {
		return nil, nil, ""
	}
	people := map[string]string{} // lower-cased name -> person item key
	for _, p := range b.people {
		people[p.name] = p.key
	}
	noteEnt := EntityID(b.s.User, noteKey)
	node := map[string]string{} // lower-cased entity name -> node id
	linked := map[string]bool{}
	var shown []string
	for _, e := range x.Entities {
		shown = append(shown, e.Name)
		id := ""
		if e.Type == "person" {
			for _, n := range append([]string{e.Name}, e.Aliases...) {
				if pk, ok := people[strings.ToLower(n)]; ok {
					*rels = append(*rels, rel{to: pk, typ: RelAbout})
					id = EntityID(b.s.User, pk)
					break
				}
			}
		}
		if id == "" {
			id = TopicID(b.s.User, e.Type, e.Name)
			if !linked[id] {
				meta := map[string]string{"source": "noted", "noted_user": b.s.User, "topic_type": e.Type}
				if len(e.Aliases) > 0 {
					meta["aliases"] = strings.Join(e.Aliases, ", ")
				}
				extra = append(extra, cortexdb.ToolEntityInput{ID: id, Name: e.Name, Type: "noted_topic_" + e.Type, Metadata: meta})
				extraRel = append(extraRel, cortexdb.ToolRelationInput{From: noteEnt, To: id, Type: RelAbout})
			}
		}
		linked[id] = true
		node[strings.ToLower(e.Name)] = id
	}
	seen := map[string]bool{}
	for _, r := range x.Relations {
		from, to := node[strings.ToLower(r.From)], node[strings.ToLower(r.To)]
		k := from + " " + r.Type + " " + to
		if from == "" || to == "" || from == to || seen[k] {
			continue
		}
		seen[k] = true
		extraRel = append(extraRel, cortexdb.ToolRelationInput{From: from, To: to, Type: r.Type, Metadata: map[string]string{"from_note": noteKey}})
	}
	return extra, extraRel, strings.Join(shown, ", ")
}

// extractNotes fills snap.Extractions for the notes in the snapshot from the
// cache, and with an Extractor and no dry run reads up to PerRun notes whose
// text changed (most recently edited first) and stores what it finds. A note
// the model fails on keeps its earlier result, and is tried again next run.
// Extractions of notes no longer in the snapshot are dropped.
func (s *Syncer) extractNotes(ctx context.Context, userID string, snap *Snapshot, dry bool, rep *Report) error {
	snap.Extractions = map[string]Extraction{}
	if !s.Extract {
		return nil
	}
	cache, err := s.Store.CortexExtractions(ctx, userID)
	if err != nil {
		return err
	}
	live := map[string]bool{}
	var stale []store.Note
	for _, n := range snap.Notes {
		live[n.ID] = true
		h := TextHash(n.Title, n.Content)
		c, ok := cache[n.ID]
		var x Extraction
		parsed := ok && json.Unmarshal([]byte(c.Result), &x) == nil
		if parsed {
			snap.Extractions[n.ID] = x // the earlier result stands until a new one replaces it
		}
		if !parsed || c.Hash != h {
			stale = append(stale, n)
		}
	}
	if dry {
		return nil
	}
	var gone []string
	for id := range cache {
		if !live[id] {
			gone = append(gone, id)
		}
	}
	if len(gone) > 0 {
		sort.Strings(gone)
		if err := s.Store.CortexExtractionDrop(ctx, userID, gone); err != nil {
			return err
		}
	}
	var todo []store.Note
	for _, n := range stale {
		if !Readable(n) {
			// Too short to name anything: an empty result replaces an old one.
			if err := s.Store.CortexExtractionPut(ctx, userID, n.ID, TextHash(n.Title, n.Content), `{"entities":[],"relations":[]}`, time.Now()); err != nil {
				return err
			}
			delete(snap.Extractions, n.ID)
			continue
		}
		todo = append(todo, n)
	}
	stale = todo
	if s.Extractor == nil || len(stale) == 0 {
		return nil
	}
	sort.SliceStable(stale, func(i, j int) bool { return stale[i].Updated.After(stale[j].Updated) })
	limit := s.PerRun
	if limit <= 0 {
		limit = defaultPerRun
	}
	failing := 0
	for _, n := range stale {
		if ctx.Err() != nil || rep.Extracted+rep.ExtractFailed >= limit || failing >= stopAfterFailing {
			break
		}
		cctx, cancel := s.callCtx(ctx)
		x, err := s.Extractor.Extract(cctx, n.Title, n.Content)
		cancel()
		if err != nil {
			failing++
			rep.ExtractFailed++
			if rep.ExtractErr == "" {
				rep.ExtractErr = firstLine(err.Error())
			}
			continue
		}
		failing = 0
		body, _ := json.Marshal(x)
		if err := s.Store.CortexExtractionPut(ctx, userID, n.ID, TextHash(n.Title, n.Content), string(body), time.Now()); err != nil {
			return err
		}
		snap.Extractions[n.ID] = x
		rep.Extracted++
	}
	return nil
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(s, "\n")
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

// Readable reports whether a note has enough text to be worth reading.
func Readable(n store.Note) bool {
	return utf8.RuneCountInString(strings.TrimSpace(n.Title+n.Content)) >= minExtractRunes
}

// Pending is a note whose extraction is missing or out of date.
type Pending struct {
	Note store.Note
	Hash string
}

// PendingNotes lists the user's notes that need reading, most recently edited
// first, up to limit, and how many more there are. Only notes in spaces the
// user lets AI read are considered.
func PendingNotes(ctx context.Context, st *store.Store, userID string, limit int) (out []Pending, more int, err error) {
	access, err := st.GetAIAccess(ctx, userID)
	if err != nil {
		return nil, 0, err
	}
	cache, err := st.CortexExtractions(ctx, userID)
	if err != nil {
		return nil, 0, err
	}
	var all []Pending
	for off := 0; ; off += pageSize {
		ns, err := st.ListNotes(ctx, userID, store.NoteFilter{IncludeArchived: true, Limit: pageSize, Offset: off})
		if err != nil {
			return nil, 0, err
		}
		for _, n := range ns {
			if !access.Allows(n.Space) || !Readable(n) {
				continue
			}
			h := TextHash(n.Title, n.Content)
			if c, ok := cache[n.ID]; ok && c.Hash == h {
				continue
			}
			all = append(all, Pending{Note: n, Hash: h})
		}
		if len(ns) < pageSize {
			break
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].Note.Updated.After(all[j].Note.Updated) })
	if limit > 0 && len(all) > limit {
		return all[:limit], len(all) - limit, nil
	}
	return all, 0, nil
}

// Submit stores an outside reader's answer for a note, if the note has not
// changed since the hash was made and its space may be read by AI. It reports
// whether it was stored, and what the cleaning kept.
func Submit(ctx context.Context, st *store.Store, userID, noteID, hash, result string) (stored bool, x Extraction, err error) {
	x, err = ParseExtraction(result)
	if err != nil {
		return false, x, err
	}
	n, err := st.GetNote(ctx, userID, noteID)
	if err != nil {
		return false, x, err
	}
	access, err := st.GetAIAccess(ctx, userID)
	if err != nil {
		return false, x, err
	}
	if !access.Allows(n.Space) || hash != TextHash(n.Title, n.Content) {
		return false, x, nil
	}
	body, _ := json.Marshal(x)
	return true, x, st.CortexExtractionPut(ctx, userID, noteID, hash, string(body), time.Now())
}
