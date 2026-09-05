from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from copy import deepcopy
from pathlib import Path

SLUG = re.compile(r"[^a-z0-9]+")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def decode_layout(raw: bytes) -> str:
    return raw.decode("utf-16-le").lstrip("\ufeff")


def encode_layout(text: str, raw: bytes) -> bytes:
    encoded = text.encode("utf-16-le")
    return b"\xff\xfe" + encoded if raw.startswith(b"\xff\xfe") else encoded


def label(index: int, name: str) -> str:
    slug = SLUG.sub("-", name.casefold()).strip("-") or "page"
    return f"{index:02d}-{slug}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    args = parser.parse_args()

    candidate = args.candidate.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(candidate, "r") as z:
        bad = z.testzip()
        if bad:
            raise ValueError(f"PBIX CRC failure in {bad}")
        infos = z.infolist()
        members = {info.filename: z.read(info.filename) for info in infos}
    raw = members["Report/Layout"]
    layout = json.loads(decode_layout(raw))
    sections = layout.get("sections")
    if not isinstance(sections, list) or not sections:
        raise ValueError("PBIX has no report sections")

    pages = []
    for index, section in enumerate(sections):
        if not isinstance(section, dict):
            raise ValueError(f"invalid section at {index}")
        display_name = section.get("displayName")
        if not isinstance(display_name, str) or not display_name:
            raise ValueError(f"section {index} has no displayName")
        visual_count = len(section.get("visualContainers") or [])
        page_label = label(index, display_name)
        variant_layout = deepcopy(layout)
        report_config = json.loads(variant_layout.get("config") or "{}")
        report_config["activeSectionIndex"] = index
        variant_layout["config"] = json.dumps(report_config, ensure_ascii=False, separators=(",", ":"))
        variant_raw = encode_layout(
            json.dumps(variant_layout, ensure_ascii=False, separators=(",", ":")), raw
        )
        output = args.output_dir / f"{page_label}.pbix"
        with zipfile.ZipFile(output, "w") as out:
            for info in infos:
                out.writestr(info, variant_raw if info.filename == "Report/Layout" else members[info.filename])
        with zipfile.ZipFile(output, "r") as check:
            bad = check.testzip()
            if bad:
                raise ValueError(f"variant CRC failure in {bad}")
            for name, payload in members.items():
                if name == "Report/Layout":
                    continue
                if check.read(name) != payload:
                    raise ValueError(f"non-layout member changed in {page_label}: {name}")
        pages.append(
            {
                "index": index,
                "display_name": display_name,
                "internal_name": section.get("name"),
                "label": page_label,
                "visual_count": visual_count,
                "variant": str(output),
            }
        )

    evidence = {
        "ok": True,
        "candidate_pbix_sha256": sha256_file(candidate),
        "page_count": len(pages),
        "total_visuals": sum(p["visual_count"] for p in pages),
        "pages": pages,
    }
    args.inventory.parent.mkdir(parents=True, exist_ok=True)
    args.inventory.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(evidence, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
