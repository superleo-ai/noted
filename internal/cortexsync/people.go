package cortexsync

import (
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/liliang-cn/noted/internal/store"
)

// personName is one way an item's words can name a person.
type personName struct {
	key  string // the person's item key
	name string // lower-cased
}

// peopleMatcher is the names to look for, longest first, so "三宝妈" is found
// before "三宝". A one-letter name would match almost anything and is left
// out; so is a name two people share.
func peopleMatcher(people []store.Person) []personName {
	count := map[string]int{}
	for _, p := range people {
		count[strings.ToLower(strings.TrimSpace(p.Name))]++
	}
	var out []personName
	for _, p := range people {
		n := strings.ToLower(strings.TrimSpace(p.Name))
		if utf8.RuneCountInString(n) < 2 || count[n] > 1 {
			continue
		}
		out = append(out, personName{key: key(KindPerson, p.ID), name: n})
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i].name) > len(out[j].name) })
	return out
}

// named is the people an item's title and content name. A name inside a
// longer one already found ("三宝" in "三宝妈") does not count again.
func (b *builder) named(title string, content []string) []string {
	if len(b.people) == 0 {
		return nil
	}
	text := strings.ToLower(title + "\n" + strings.Join(content, "\n"))
	var out []string
	for _, p := range b.people {
		if i := strings.Index(text, p.name); i >= 0 {
			out = append(out, p.key)
			text = strings.ReplaceAll(text, p.name, "\x00")
		}
	}
	return out
}

// person writes someone in the user's life: their name and every field kept
// about them (relation, birthday, phone, notes), in a stable order.
func (b *builder) person(p store.Person) {
	keys := make([]string, 0, len(p.Fields))
	for k := range p.Fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	content := []string{b.l.kindPerson + "：" + p.Name}
	meta := map[string]string{"updated": b.date(p.Updated)}
	var desc []string
	for _, k := range keys {
		v := strings.TrimSpace(p.Fields[k])
		if v == "" {
			continue
		}
		content = append(content, k+"："+v)
		if len(desc) < 3 && utf8.RuneCountInString(v) <= 40 {
			desc = append(desc, k+" "+v)
		}
	}
	b.emit(record{
		kind: KindPerson, id: p.ID, title: b.l.kindPerson + "：" + p.Name, name: p.Name,
		desc:    line(append([]string{b.l.kindPerson}, desc...)...),
		content: content,
		meta:    meta,
	})
}
