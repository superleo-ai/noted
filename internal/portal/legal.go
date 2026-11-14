package portal

import (
	"bytes"
	"embed"
	"html/template"
	"net/http"
	"strings"
)

// The model provider the hosted service sends AI requests to. The iOS app
// names it in AIConsent.providerName; change both together (and bump the
// app's consent version so everyone is asked again).
const aiProvider = "OpenAI（GPT）"

// When the policy pages last changed in substance.
const (
	legalUpdated   = "2026 年 11 月 11 日"
	legalUpdatedEN = "November 11, 2026"
)

//go:embed legal
var legalFS embed.FS

type legalPage struct {
	Title      string
	Provider   string
	ProviderEN string
	Updated    string
	UpdatedEN  string
	Stylesheet string
	GitHub     string
	Email      string
}

// legalPages renders /privacy, /terms and /support once: they do not depend
// on the request.
func legalPages() map[string][]byte {
	data := legalPage{
		Provider:   aiProvider,
		ProviderEN: strings.NewReplacer("（", " (", "）", ")").Replace(aiProvider),
		Updated:    legalUpdated,
		UpdatedEN:  legalUpdatedEN,
		Stylesheet: StylesheetURL(),
		GitHub:     "https://github.com/superleo-ai/noted",
		Email:      "noted@superleo.app",
	}
	titles := map[string]string{"privacy": "隐私政策", "terms": "用户协议", "support": "支持"}
	out := map[string][]byte{}
	for name, title := range titles {
		t := template.Must(template.ParseFS(legalFS, "legal/layout.html", "legal/"+name+".html"))
		d := data
		d.Title = title
		var b bytes.Buffer
		if err := t.ExecuteTemplate(&b, "layout", d); err != nil {
			panic("portal: " + name + ": " + err.Error())
		}
		out["/"+name] = b.Bytes()
	}
	return out
}

func serveLegal(body []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write(body)
	}
}
