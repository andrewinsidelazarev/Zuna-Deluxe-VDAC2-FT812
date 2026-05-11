#!/usr/bin/env python3
"""make_pdf.py — конвертирует uchebnik_tsconf_vdac2.md → HTML → PDF.

Использует:
- python-markdown с extensions: fenced_code, tables, toc, codehilite.
- pygments для syntax highlighting.
- weasyprint для рендера в PDF.

Output: uchebnik_tsconf_vdac2.html, uchebnik_tsconf_vdac2.pdf.
"""
import os
import subprocess
import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'uchebnik_tsconf_vdac2.md')
OUT_HTML = os.path.join(HERE, 'uchebnik_tsconf_vdac2.html')
OUT_PDF = os.path.join(HERE, 'uchebnik_tsconf_vdac2.pdf')


CSS_STYLE = """
@page {
    size: A4;
    margin: 2cm 2cm 2.5cm 2cm;
    @bottom-center {
        content: counter(page) " / " counter(pages);
        font-family: Georgia, serif;
        font-size: 9pt;
        color: #666;
    }
    @top-right {
        content: "Zuma VDAC2 — учебник";
        font-family: Georgia, serif;
        font-size: 8pt;
        color: #888;
    }
}

@page :first {
    @top-right { content: ""; }
    @bottom-center { content: ""; }
}

body {
    font-family: Georgia, "Times New Roman", serif;
    font-size: 10pt;
    line-height: 1.55;
    color: #222;
    text-align: justify;
    hyphens: auto;
}

h1 {
    font-family: Georgia, serif;
    font-size: 22pt;
    color: #1a3a5a;
    border-bottom: 2px solid #1a3a5a;
    padding-bottom: 8pt;
    margin-top: 0;
    margin-bottom: 16pt;
    page-break-before: always;
    page-break-after: avoid;
}

h1:first-of-type {
    page-break-before: avoid;
}

h2 {
    font-family: Georgia, serif;
    font-size: 15pt;
    color: #2a4a7a;
    margin-top: 20pt;
    margin-bottom: 10pt;
    border-left: 4px solid #2a4a7a;
    padding-left: 8pt;
    page-break-after: avoid;
}

h3 {
    font-family: Georgia, serif;
    font-size: 12pt;
    color: #3a5a9a;
    margin-top: 16pt;
    margin-bottom: 8pt;
    page-break-after: avoid;
}

h4, h5, h6 {
    font-family: Georgia, serif;
    color: #4a6aaa;
    margin-top: 12pt;
    margin-bottom: 6pt;
    page-break-after: avoid;
}

p {
    margin: 0 0 8pt 0;
}

code {
    font-family: "Cascadia Mono", "Consolas", "Courier New", monospace;
    font-size: 9pt;
    background-color: #f0f3f7;
    color: #b03050;
    padding: 1pt 4pt;
    border-radius: 3px;
    border: 1px solid #d8dee5;
}

pre {
    font-family: "Cascadia Mono", "Consolas", "Courier New", monospace;
    font-size: 8.5pt;
    line-height: 1.35;
    background-color: #f5f7fa;
    border: 1px solid #c8d2dd;
    border-left: 3px solid #2a4a7a;
    border-radius: 3px;
    padding: 8pt 10pt;
    margin: 8pt 0;
    white-space: pre-wrap;
    word-wrap: break-word;
    page-break-inside: avoid;
}

pre code {
    background: none;
    color: #1a2a3a;
    padding: 0;
    border: none;
    border-radius: 0;
}

blockquote {
    border-left: 3px solid #c8d2dd;
    padding-left: 10pt;
    margin-left: 4pt;
    color: #555;
    font-style: italic;
}

ul, ol {
    margin: 6pt 0 8pt 0;
    padding-left: 22pt;
}

li {
    margin-bottom: 3pt;
}

table {
    border-collapse: collapse;
    margin: 10pt 0;
    width: 100%;
    font-size: 9pt;
    page-break-inside: avoid;
}

th, td {
    border: 1px solid #c8d2dd;
    padding: 4pt 8pt;
    text-align: left;
    vertical-align: top;
}

th {
    background-color: #e8eef5;
    color: #1a3a5a;
    font-weight: bold;
}

tr:nth-child(even) td {
    background-color: #fafbfd;
}

hr {
    border: none;
    border-top: 1px solid #c8d2dd;
    margin: 18pt 0;
}

a {
    color: #2a4a7a;
    text-decoration: none;
}

strong {
    color: #1a3a5a;
}

/* Pygments syntax highlighting */
.codehilite { background: #f5f7fa; }
.codehilite .c, .codehilite .c1, .codehilite .cm  { color: #708090; font-style: italic; }   /* comments */
.codehilite .k, .codehilite .kd, .codehilite .kr  { color: #2070a0; font-weight: bold; }    /* keywords */
.codehilite .nv, .codehilite .nb                  { color: #b04030; }                       /* names */
.codehilite .s, .codehilite .s1, .codehilite .s2  { color: #408060; }                       /* strings */
.codehilite .mi, .codehilite .mh, .codehilite .mf { color: #b04060; }                       /* numbers */
.codehilite .o                                     { color: #555; }                          /* operators */
.codehilite .nf                                    { color: #b04020; font-weight: bold; }    /* function name */

/* Title page */
.title-page {
    text-align: center;
    padding-top: 6cm;
    page-break-after: always;
}
.title-page h1 {
    border: none;
    page-break-before: avoid;
    font-size: 32pt;
    color: #1a3a5a;
    margin-bottom: 12pt;
}
.title-page .subtitle {
    font-size: 16pt;
    color: #4a6aaa;
    font-style: italic;
    margin-bottom: 80pt;
}
.title-page .meta {
    font-size: 11pt;
    color: #555;
}
"""


def main():
    print(f'Reading {SRC}')
    with open(SRC, 'r', encoding='utf-8') as f:
        md_text = f.read()

    md = markdown.Markdown(extensions=['fenced_code', 'tables', 'toc', 'codehilite'],
                           extension_configs={
                               'codehilite': {'css_class': 'codehilite',
                                               'guess_lang': False},
                               'toc': {'title': 'Содержание', 'toc_depth': '2-3'},
                           })
    body_html = md.convert(md_text)
    toc_html = md.toc

    # Title page
    title_html = '''
    <div class="title-page">
        <h1>Zuma VDAC2</h1>
        <div class="subtitle">Порт под FT812 / 640×480<br>Учебник по разработке</div>
        <div class="meta">
            ZX-Evo · TS-Conf · Z80 · FT81x<br>
            Сквозной пример: классическая Zuma на нативном железе<br>
            Версия: baseline 2026-05-10 (full HD frog composition)
        </div>
    </div>
    '''

    full_html = f'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>Zuma VDAC2 — Учебник</title>
<style>{CSS_STYLE}</style>
</head>
<body>
{title_html}
<h1 style="page-break-before: avoid">Содержание</h1>
{toc_html}
{body_html}
</body>
</html>
'''

    print(f'Writing {OUT_HTML}')
    with open(OUT_HTML, 'w', encoding='utf-8') as f:
        f.write(full_html)

    # Render PDF via Microsoft Edge headless (Chromium).
    print(f'Rendering PDF → {OUT_PDF} via Edge headless')
    edge_paths = [
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    ]
    edge = next((p for p in edge_paths if os.path.exists(p)), None)
    if not edge:
        print('  (Edge не найден — открой uchebnik_tsconf_vdac2.html в браузере и Ctrl+P → Save as PDF)')
        return
    file_url = 'file:///' + OUT_HTML.replace('\\', '/')
    cmd = [
        edge,
        '--headless=new',
        '--disable-gpu',
        '--no-pdf-header-footer',
        f'--print-to-pdf={OUT_PDF}',
        file_url,
    ]
    print('  ', ' '.join(cmd))
    subprocess.run(cmd, check=True, timeout=120)
    print(f'Done. PDF size: {os.path.getsize(OUT_PDF)} bytes')


if __name__ == '__main__':
    main()
