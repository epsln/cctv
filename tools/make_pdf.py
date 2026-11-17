#!/usr/bin/env python3
"""Write a minimal multi-page text PDF (no dependencies). Used for sample assets.

usage: make_pdf.py OUT.pdf "page one line|line two" "page two..." ...
"""
import sys


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build(pages: list[str]) -> bytes:
    n = len(pages)
    font_id = 3 + 2 * n
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [%s] /Count %d >>"
        % (b" ".join(b"%d 0 R" % (3 + i) for i in range(n)), n),
    ]
    for i in range(n):
        objs.append(
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R "
            b"/Resources << /Font << /F1 %d 0 R >> >> >>" % (3 + n + i, font_id)
        )
    for text in pages:
        lines = text.split("|")
        ops = ["BT /F1 14 Tf 18 TL 60 720 Td"]
        ops += ["(%s) '" % esc(l) for l in lines]
        ops.append("ET")
        # redaction-like bars
        ops.append("0 0 0 rg 60 420 300 14 re f 60 396 380 14 re f")
        body = "\n".join(ops).encode()
        objs.append(b"<< /Length %d >>\nstream\n" % len(body) + body + b"\nendstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")
    out = b"%PDF-1.4\n"
    offs = []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += b"%d 0 obj\n" % (i + 1) + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % v for v in offs)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    return out


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as f:
        f.write(build(sys.argv[2:]))
