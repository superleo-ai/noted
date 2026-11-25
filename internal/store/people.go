package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

// A Person is someone in the user's life. The name is unique per user,
// ignoring case; everything else worth remembering about them (relation,
// phone, birthday, notes, what they are up to) is a free-form field, so a new
// kind of detail needs no migration.
type Person struct {
	ID      string
	UserID  string
	Name    string
	Fields  map[string]string
	Created time.Time
	Updated time.Time
}

const (
	maxPersonName   = 100
	maxPersonKey    = 40
	maxPersonValue  = 2000
	maxPersonFields = 50
	maxPeople       = 5000
)

func (s *Store) migratePeople(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS people (
	id         TEXT PRIMARY KEY,
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	name       TEXT NOT NULL,
	name_key   TEXT NOT NULL,
	fields     TEXT NOT NULL DEFAULT '{}',
	created_ms INTEGER NOT NULL,
	updated_ms INTEGER NOT NULL,
	UNIQUE (user_id, name_key)
)`)
	return err
}

// personKey is what makes two names the same person.
func personKey(name string) string { return strings.ToLower(strings.TrimSpace(name)) }

func personName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", invalid("name is required")
	}
	if utf8.RuneCountInString(name) > maxPersonName {
		return "", invalid("name is longer than %d characters", maxPersonName)
	}
	return name, nil
}

// encodeFields writes the fields as JSON without HTML escaping, so the
// stored text reads as the person wrote it.
func encodeFields(f map[string]string) (string, error) {
	if f == nil {
		f = map[string]string{}
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(f); err != nil {
		return "", err
	}
	return strings.TrimSpace(b.String()), nil
}

const personCols = `id, user_id, name, fields, created_ms, updated_ms`

func scanPerson(r scanner) (Person, error) {
	var p Person
	var fields string
	var created, updated int64
	if err := r.Scan(&p.ID, &p.UserID, &p.Name, &fields, &created, &updated); err != nil {
		return Person{}, err
	}
	p.Fields = map[string]string{}
	_ = json.Unmarshal([]byte(fields), &p.Fields)
	p.Created, p.Updated = fromMS(created), fromMS(updated)
	return p, nil
}

func (s *Store) personBy(ctx context.Context, q queryer, userID, id, name string) (Person, error) {
	var row *sql.Row
	switch {
	case strings.TrimSpace(id) != "":
		row = q.QueryRowContext(ctx, `SELECT `+personCols+` FROM people WHERE user_id = ? AND id = ?`, userID, strings.TrimSpace(id))
	case strings.TrimSpace(name) != "":
		row = q.QueryRowContext(ctx, `SELECT `+personCols+` FROM people WHERE user_id = ? AND name_key = ?`, userID, personKey(name))
	default:
		return Person{}, invalid("id or name is required")
	}
	p, err := scanPerson(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Person{}, ErrNotFound
	}
	return p, err
}

// queryer is what personBy needs from a *sql.DB or a *sql.Tx.
type queryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// GetPerson finds a person by id, or by name ignoring case when id is empty.
func (s *Store) GetPerson(ctx context.Context, userID, id, name string) (Person, error) {
	return s.personBy(ctx, s.db, userID, id, name)
}

// UpsertPerson creates the person of that name, or merges into the one there
// is: each field given is set, a field given empty is removed, the rest keep
// their value. newName, when given, renames them.
func (s *Store) UpsertPerson(ctx context.Context, userID, name string, fields map[string]string, newName string, now time.Time) (Person, error) {
	name, err := personName(name)
	if err != nil {
		return Person{}, err
	}
	if strings.TrimSpace(newName) != "" {
		if newName, err = personName(newName); err != nil {
			return Person{}, err
		}
	}
	for k, v := range fields {
		k = strings.TrimSpace(k)
		if k == "" {
			return Person{}, invalid("a field needs a name")
		}
		if utf8.RuneCountInString(k) > maxPersonKey {
			return Person{}, invalid("field name %q is longer than %d characters", k, maxPersonKey)
		}
		if utf8.RuneCountInString(v) > maxPersonValue {
			return Person{}, invalid("field %q is longer than %d characters", k, maxPersonValue)
		}
	}
	var out Person
	err = s.tx(ctx, func(tx *sql.Tx) error {
		p, err := s.personBy(ctx, tx, userID, "", name)
		isNew := errors.Is(err, ErrNotFound)
		if err != nil && !isNew {
			return err
		}
		if isNew {
			var n int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM people WHERE user_id = ?`, userID).Scan(&n); err != nil {
				return err
			}
			if n >= maxPeople {
				return precondition("at most %d people", maxPeople)
			}
			p = Person{ID: uuid.NewString(), UserID: userID, Name: name, Fields: map[string]string{}, Created: now}
		}
		for k, v := range fields {
			k, v = strings.TrimSpace(k), strings.TrimSpace(v)
			if v == "" {
				delete(p.Fields, k)
			} else {
				p.Fields[k] = v
			}
		}
		if len(p.Fields) > maxPersonFields {
			return invalid("at most %d fields per person", maxPersonFields)
		}
		if newName != "" && personKey(newName) != personKey(p.Name) {
			if _, err := s.personBy(ctx, tx, userID, "", newName); err == nil {
				return invalid("%q is already someone else", newName)
			} else if !errors.Is(err, ErrNotFound) {
				return err
			}
		}
		if newName != "" {
			p.Name = newName
		}
		enc, err := encodeFields(p.Fields)
		if err != nil {
			return err
		}
		p.Updated = now
		if isNew {
			_, err = tx.ExecContext(ctx, `INSERT INTO people (id, user_id, name, name_key, fields, created_ms, updated_ms) VALUES (?, ?, ?, ?, ?, ?, ?)`,
				p.ID, userID, p.Name, personKey(p.Name), enc, ms(p.Created), ms(now))
		} else {
			_, err = tx.ExecContext(ctx, `UPDATE people SET name = ?, name_key = ?, fields = ?, updated_ms = ? WHERE id = ? AND user_id = ?`,
				p.Name, personKey(p.Name), enc, ms(now), p.ID, userID)
		}
		if err != nil {
			return err
		}
		p.Created, p.Updated = fromMS(ms(p.Created)), fromMS(ms(now))
		out = p
		return nil
	})
	return out, err
}

// ListPeople returns the people whose name or any field value contains query
// (ignoring case), by name; an empty query is everyone.
func (s *Store) ListPeople(ctx context.Context, userID, query string, limit int) ([]Person, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+personCols+` FROM people WHERE user_id = ? ORDER BY name_key`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	words := strings.Fields(strings.ToLower(query))
	out := []Person{}
	for rows.Next() {
		p, err := scanPerson(rows)
		if err != nil {
			return nil, err
		}
		if !personMatches(p, words) {
			continue
		}
		out = append(out, p)
		if len(out) >= limit {
			break
		}
	}
	return out, rows.Err()
}

// personMatches says whether every word is in the name, a field name or a
// field value.
func personMatches(p Person, words []string) bool {
	if len(words) == 0 {
		return true
	}
	keys := make([]string, 0, len(p.Fields))
	for k := range p.Fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(strings.ToLower(p.Name))
	for _, k := range keys {
		b.WriteString("\n" + strings.ToLower(k) + " " + strings.ToLower(p.Fields[k]))
	}
	blob := b.String()
	for _, w := range words {
		if !strings.Contains(blob, w) {
			return false
		}
	}
	return true
}

// DeletePerson removes a person by id, or by name ignoring case.
func (s *Store) DeletePerson(ctx context.Context, userID, id, name string) error {
	p, err := s.GetPerson(ctx, userID, id, name)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM people WHERE id = ? AND user_id = ?`, p.ID, userID)
	return err
}
