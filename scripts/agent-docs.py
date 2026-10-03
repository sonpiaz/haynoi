#!/usr/bin/env python3
"""Markdown copies of haynoi.com's content pages, for agents.

Writes, from the HTML that is already the source of truth:
  site/index.md, site/changelog.md   one per content page (URL + .md)
  site/llms-full.txt                 llms.txt followed by every .md page
Run before committing a site change; the outputs are committed, because
deploy-site.sh only uploads tracked files. Stdlib only.
"""
from html.parser import HTMLParser
from urllib.parse import urljoin
from pathlib import Path
import re

SITE = Path(__file__).resolve().parent.parent / "site"
BASE = "https://haynoi.com"
PAGES = [("index.html", "index.md"), ("changelog/index.html", "changelog.md")]
SKIP = {"script", "style", "svg", "noscript", "button", "form", "head", "template"}
BLOCK = {"h1": "# ", "h2": "## ", "h3": "### ", "p": "", "li": "- ", "dt": "**", "dd": ""}
# Changelog markup: a release head (version + date spans) is a heading, its tagline italic.
CLASS_BLOCK = {"release-head": "rel", "release-tagline": "tag"}


class ToMarkdown(HTMLParser):
    def __init__(self, url: str):
        super().__init__(convert_charrefs=True)
        self.url = url
        self.out, self.buf, self.skip, self.block, self.href = [], [], 0, None, None
        self.after_span = False

    def handle_starttag(self, tag, attrs):
        after_span, self.after_span = self.after_span, False
        if tag in SKIP:
            self.skip += 1
        elif self.skip:
            return
        elif any(c in CLASS_BLOCK for c in (dict(attrs).get("class") or "").split()):
            self.flush()
            self.block = next(CLASS_BLOCK[c] for c in dict(attrs)["class"].split() if c in CLASS_BLOCK)
            self.close_on = tag
        elif tag in BLOCK:
            self.flush()
            self.block = tag
        elif tag in ("div", "section", "header", "footer", "nav", "article") and not self.block:
            self.flush()
        elif tag == "span" and self.block == "rel" and "".join(self.buf).strip():
            self.buf.append(" — ")
        elif tag == "span" and after_span:
            self.buf.append(" ")                   # sibling spans: "Haynoi" "MIT", not "HaynoiMIT"
        elif tag == "br":
            self.buf.append(" ")
        elif tag == "a":
            href = dict(attrs).get("href") or ""
            if href.startswith("#") or not href:
                self.href = None                   # in-page anchor: plain text
                return
            self.href = urljoin(self.url, href)
            self.buf.append("[")
        elif tag in ("strong", "b"):
            self.buf.append("**")
        elif tag in ("em", "i"):
            self.buf.append("*")

    def handle_endtag(self, tag):
        self.after_span = tag == "span"
        if tag in SKIP:
            self.skip = max(0, self.skip - 1)
        elif self.skip:
            return
        elif tag in BLOCK or (self.block in ("rel", "tag") and tag == getattr(self, "close_on", None)):
            self.flush()
        elif tag in ("ul", "ol", "dl"):
            self.out.append("")
        elif tag in ("div", "section", "header", "footer", "nav", "article") and not self.block:
            self.flush()
        elif tag == "a" and self.href is not None:
            self.buf.append(f"]({self.href})")
            self.href = None
        elif tag in ("strong", "b"):
            self.buf.append("**")
        elif tag in ("em", "i"):
            self.buf.append("*")

    def handle_data(self, data):
        if data.strip():
            self.after_span = False
        if not self.skip:
            self.buf.append(data)

    def flush(self):
        text = re.sub(r"\s+", " ", "".join(self.buf)).strip()
        text = re.sub(r"\[\s*\]\([^)]*\)", "", text).replace("****", "").strip()
        text = re.sub(r"\[\s+", "[", re.sub(r"\s+\]\(", "](", text))
        if text and not self.block:
            # Text outside a block element (a price strip, a label in a div):
            # still content, written as its own paragraph.
            self.out += [text, ""]
        elif text and self.block:
            if self.block == "rel":
                line = "## " + text
            elif self.block == "tag":
                line = f"*{text}*"
            else:
                line = BLOCK[self.block] + text
            if self.block == "dt":
                line += "**"
            if self.block in ("h1", "h2", "h3", "rel"):
                self.out.append("")
            self.out.append(line)
            if self.block in ("h1", "h2", "h3", "p", "dd", "rel", "tag"):
                self.out.append("")
        self.buf, self.block = [], None


def to_md(html: str, url: str) -> str:
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    p = ToMarkdown(url)
    p.feed(html)
    p.flush()
    body = re.sub(r"\n{3,}", "\n\n", "\n".join(p.out)).strip()
    head = f"# {title.group(1).strip()}\n\nSource: {url}\n" if title else ""
    return f"{head}\n{body}\n"


def main():
    docs = []
    for src, dst in PAGES:
        url = BASE + "/" + (src[: -len("index.html")])
        md = to_md((SITE / src).read_text(encoding="utf-8"), url)
        (SITE / dst).write_text(md, encoding="utf-8")
        docs.append(md)
    llms = (SITE / "llms.txt").read_text(encoding="utf-8").rstrip()
    (SITE / "llms-full.txt").write_text(llms + "\n\n---\n\n" + "\n---\n\n".join(docs), encoding="utf-8")
    for name in ["llms.txt", "llms-full.txt"] + [d for _, d in PAGES]:
        print(f"{name}: {(SITE / name).stat().st_size} bytes")


if __name__ == "__main__":
    main()
