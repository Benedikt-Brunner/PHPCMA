#!/usr/bin/env python3

"""Compare PHPCMA symbol JSON against PHP reflection JSON."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class Mismatch:
    fqcn: str
    kind: str
    detail: str


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def list_by_name(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {item["name"]: item for item in items}


def compare_method(
    fqcn: str,
    phpcma_method: dict[str, Any],
    php_method: dict[str, Any],
    mismatches: list[Mismatch],
) -> None:
    for field in ("visibility", "is_static", "is_abstract"):
        if phpcma_method.get(field) != php_method.get(field):
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="method_field_mismatch",
                    detail=(
                        f"Method '{php_method.get('name')}' field '{field}' differs: "
                        f"PHPCMA={phpcma_method.get(field)!r}, PHP={php_method.get(field)!r}"
                    ),
                )
            )

    if phpcma_method.get("return_type") != php_method.get("return_type"):
        mismatches.append(
            Mismatch(
                fqcn=fqcn,
                kind="method_field_mismatch",
                detail=(
                    f"Method '{php_method.get('name')}' return_type differs: "
                    f"PHPCMA={phpcma_method.get('return_type')!r}, PHP={php_method.get('return_type')!r}"
                ),
            )
        )

    phpcma_params = phpcma_method.get("params", [])
    php_params = php_method.get("params", [])
    if len(phpcma_params) != len(php_params):
        mismatches.append(
            Mismatch(
                fqcn=fqcn,
                kind="method_field_mismatch",
                detail=(
                    f"Method '{php_method.get('name')}' param count differs: "
                    f"PHPCMA={len(phpcma_params)}, PHP={len(php_params)}"
                ),
            )
        )
        return

    for index, (phpcma_param, php_param) in enumerate(zip(phpcma_params, php_params)):
        if phpcma_param.get("name") != php_param.get("name"):
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="method_field_mismatch",
                    detail=(
                        f"Method '{php_method.get('name')}' param #{index} name differs: "
                        f"PHPCMA={phpcma_param.get('name')!r}, PHP={php_param.get('name')!r}"
                    ),
                )
            )
        if phpcma_param.get("type") != php_param.get("type"):
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="method_field_mismatch",
                    detail=(
                        f"Method '{php_method.get('name')}' param '{php_param.get('name')}' type differs: "
                        f"PHPCMA={phpcma_param.get('type')!r}, PHP={php_param.get('type')!r}"
                    ),
                )
            )


def compare_property(
    fqcn: str,
    phpcma_prop: dict[str, Any],
    php_prop: dict[str, Any],
    mismatches: list[Mismatch],
) -> None:
    for field in ("visibility", "type", "is_static", "is_readonly"):
        if phpcma_prop.get(field) != php_prop.get(field):
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="property_field_mismatch",
                    detail=(
                        f"Property '{php_prop.get('name')}' field '{field}' differs: "
                        f"PHPCMA={phpcma_prop.get(field)!r}, PHP={php_prop.get(field)!r}"
                    ),
                )
            )


def compare_class(
    fqcn: str,
    phpcma_cls: dict[str, Any],
    php_cls: dict[str, Any],
    mismatches: list[Mismatch],
) -> None:
    for field in ("is_abstract", "is_final", "extends"):
        if phpcma_cls.get(field) != php_cls.get(field):
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="class_field_mismatch",
                    detail=(
                        f"Class field '{field}' differs: "
                        f"PHPCMA={phpcma_cls.get(field)!r}, PHP={php_cls.get(field)!r}"
                    ),
                )
            )

    if set(phpcma_cls.get("implements", [])) != set(php_cls.get("implements", [])):
        mismatches.append(
            Mismatch(
                fqcn=fqcn,
                kind="implements_mismatch",
                detail=(
                    "Implemented interfaces differ: "
                    f"PHPCMA={sorted(phpcma_cls.get('implements', []))!r}, "
                    f"PHP={sorted(php_cls.get('implements', []))!r}"
                ),
            )
        )

    phpcma_methods = list_by_name(phpcma_cls.get("methods", []))
    php_methods = list_by_name(php_cls.get("methods", []))
    all_method_names = sorted(set(phpcma_methods) | set(php_methods))
    for method_name in all_method_names:
        if method_name not in phpcma_methods:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="method_missing_in_phpcma",
                    detail=f"Method '{method_name}' exists in PHP reflection but not PHPCMA",
                )
            )
            continue
        if method_name not in php_methods:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="method_missing_in_php",
                    detail=f"Method '{method_name}' exists in PHPCMA but not PHP reflection",
                )
            )
            continue
        compare_method(fqcn, phpcma_methods[method_name], php_methods[method_name], mismatches)

    phpcma_props = list_by_name(phpcma_cls.get("properties", []))
    php_props = list_by_name(php_cls.get("properties", []))
    all_prop_names = sorted(set(phpcma_props) | set(php_props))
    for prop_name in all_prop_names:
        if prop_name not in phpcma_props:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="property_missing_in_phpcma",
                    detail=f"Property '{prop_name}' exists in PHP reflection but not PHPCMA",
                )
            )
            continue
        if prop_name not in php_props:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="property_missing_in_php",
                    detail=f"Property '{prop_name}' exists in PHPCMA but not PHP reflection",
                )
            )
            continue
        compare_property(fqcn, phpcma_props[prop_name], php_props[prop_name], mismatches)


def compare(phpcma_data: dict[str, Any], php_data: dict[str, Any]) -> dict[str, Any]:
    phpcma_classes = {
        item["fqcn"]: item
        for item in phpcma_data.get("classes", [])
    }
    php_classes = {
        item["fqcn"]: item
        for item in php_data.get("classes", [])
    }

    all_classes = sorted(set(phpcma_classes) | set(php_classes))
    mismatches: list[Mismatch] = []
    class_match_count = 0
    class_mismatch_count = 0

    for fqcn in all_classes:
        start_count = len(mismatches)

        if fqcn not in phpcma_classes:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="class_missing_in_phpcma",
                    detail="Class exists in PHP reflection but not PHPCMA",
                )
            )
        elif fqcn not in php_classes:
            mismatches.append(
                Mismatch(
                    fqcn=fqcn,
                    kind="class_missing_in_php",
                    detail="Class exists in PHPCMA but not PHP reflection",
                )
            )
        else:
            compare_class(fqcn, phpcma_classes[fqcn], php_classes[fqcn], mismatches)

        if len(mismatches) == start_count:
            class_match_count += 1
        else:
            class_mismatch_count += 1

    return {
        "total_classes": len(all_classes),
        "class_matches": class_match_count,
        "class_mismatches": class_mismatch_count,
        "total_mismatches": len(mismatches),
        "mismatches": [
            {"fqcn": item.fqcn, "kind": item.kind, "detail": item.detail}
            for item in mismatches
        ],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phpcma", required=True, help="Path to PHPCMA symbol JSON")
    parser.add_argument("--reflect", required=True, help="Path to reflection JSON")
    parser.add_argument("--output", required=True, help="Path to summary JSON output")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    phpcma_data = load_json(Path(args.phpcma))
    php_data = load_json(Path(args.reflect))
    summary = compare(phpcma_data, php_data)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
