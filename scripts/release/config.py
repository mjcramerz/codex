#!/usr/bin/env python3
"""Generate a commented example .mcr/config.toml from the current config schema."""

import argparse
import json
from pathlib import Path
from typing import Any

from release_contract import load_inventory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a commented example .mcr/config.toml from config.schema.json.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Repository root to read from.",
    )
    parser.add_argument(
        "--schema-path",
        type=Path,
        default=None,
        help="Explicit config schema path. Defaults to <repo-root>/codex-rs/core/config.schema.json.",
    )
    parser.add_argument(
        "--output-file",
        type=Path,
        default=None,
        help="Destination config.toml path. Defaults to <repo-root>/.mcr/config.toml.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    schema_path = (
        args.schema_path.resolve()
        if args.schema_path is not None
        else repo_root / "codex-rs" / "core" / "config.schema.json"
    )
    output_file = (
        args.output_file.resolve()
        if args.output_file is not None
        else repo_root / ".mcr" / "config.toml"
    )

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    placeholders, companion_templates = load_instruction_inventory(repo_root)
    lines = render_config(
        schema,
        schema_path,
        repo_root,
        placeholders,
        companion_templates,
    )
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Generated config placeholder at {output_file}")
    return 0


def load_instruction_inventory(
    repo_root: Path,
) -> tuple[dict[tuple[str, ...], str], dict[tuple[str, ...], str]]:
    inventory_path, inventory = load_inventory(repo_root)
    placeholders: dict[tuple[str, ...], str] = {}
    companion_templates: dict[tuple[str, ...], str] = {}
    bound_paths: dict[tuple[str, ...], str] = {}

    for asset in inventory.get("override_assets", []):
        target = f"$CODEX_HOME/.mcr/override-instructions/{asset['target']}"
        for binding in asset.get("config_bindings", []):
            path = tuple(binding["path"])
            kind = binding["kind"]
            if path in bound_paths:
                previous_target = bound_paths[path]
                raise ValueError(
                    "duplicate config binding path "
                    f"{'.'.join(path)} in {inventory_path}: "
                    f"{previous_target} and {asset['target']}"
                )
            bound_paths[path] = asset["target"]
            if kind == "file_path":
                placeholders[path] = target
            elif kind == "inline_string":
                companion_templates[path] = target

    return placeholders, companion_templates


def render_config(
    schema: dict[str, Any],
    schema_path: Path,
    repo_root: Path,
    placeholders: dict[tuple[str, ...], str],
    companion_templates: dict[tuple[str, ...], str],
) -> list[str]:
    resolved = resolve_schema(schema, schema)
    try:
        schema_label = str(schema_path.relative_to(repo_root))
    except ValueError:
        schema_label = str(schema_path)
    lines = [
        "# Example Codex config.toml generated from the reconciled schema.",
        f"# Source schema: {schema_label}",
        "#",
        "# Every setting below is commented out on purpose so this file remains",
        "# valid before you opt into any specific override. Uncomment only the",
        "# pieces you intend to use.",
        "#",
        "# Use absolute paths for file-backed settings. The examples below use",
        "# $CODEX_HOME in comments for portability; replace that with a concrete",
        "# runtime path before uncommenting a value.",
        "",
    ]

    properties = resolved.get("properties", {})
    for key, subschema in properties.items():
        lines.extend(
            render_property(
                (key,),
                resolve_schema(subschema, schema),
                schema,
                placeholders,
                companion_templates,
            )
        )
        if lines[-1] != "":
            lines.append("")

    return lines


def render_property(
    path: tuple[str, ...],
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    placeholders: dict[tuple[str, ...], str],
    companion_templates: dict[tuple[str, ...], str],
) -> list[str]:
    if is_object_schema(schema):
        return render_table(
            path,
            schema,
            root_schema,
            placeholders,
            companion_templates,
        )

    lines = description_lines(schema.get("description"))
    lines.extend(companion_template_lines(path, companion_templates))
    lines.append(
        commented_assignment(
            path[-1], example_value(path, schema, root_schema, placeholders)
        )
    )
    return lines


def render_table(
    path: tuple[str, ...],
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    placeholders: dict[tuple[str, ...], str],
    companion_templates: dict[tuple[str, ...], str],
) -> list[str]:
    properties = schema.get("properties") or {}
    additional = schema.get("additionalProperties")
    section_name = ".".join(path)
    lines = description_lines(schema.get("description"))
    lines.append(f"# [{section_name}]")

    if properties:
        for child_name, child_schema in properties.items():
            child = resolve_schema(child_schema, root_schema)
            if is_object_schema(child):
                lines.append("")
                lines.extend(
                    render_table(
                        (*path, child_name),
                        child,
                        root_schema,
                        placeholders,
                        companion_templates,
                    )
                )
            else:
                child_path = (*path, child_name)
                lines.extend(description_lines(child.get("description"), indent="# "))
                lines.extend(companion_template_lines(child_path, companion_templates))
                lines.append(
                    commented_assignment(
                        child_name,
                        example_value(child_path, child, root_schema, placeholders),
                    )
                )
    elif isinstance(additional, dict):
        example_section = (*path, "example")
        lines.append("")
        lines.extend(
            render_table(
                example_section,
                resolve_schema(additional, root_schema),
                root_schema,
                placeholders,
                companion_templates,
            )
        )
    else:
        lines.append("# <no explicit properties in schema>")

    return lines


def companion_template_lines(
    path: tuple[str, ...], companion_templates: dict[tuple[str, ...], str]
) -> list[str]:
    template_path = companion_templates.get(path)
    if template_path is None:
        return []
    return [
        "# Companion template for this inline string field:",
        f"# {template_path}",
    ]


def description_lines(description: str | None, indent: str = "# ") -> list[str]:
    if not description:
        return []
    return [f"{indent}{line}".rstrip() for line in description.strip().splitlines()]


def commented_assignment(key: str, value: str) -> str:
    return f"# {key} = {value}"


def example_value(
    path: tuple[str, ...],
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    placeholders: dict[tuple[str, ...], str],
) -> str:
    placeholder = placeholders.get(path)
    if placeholder is not None:
        return json.dumps(placeholder)

    enum_values = schema.get("enum")
    if isinstance(enum_values, list) and enum_values:
        return json.dumps(enum_values[0])

    schema_type = schema_type_name(schema)
    if schema_type == "boolean":
        return "false"
    if schema_type == "integer":
        minimum = schema.get("minimum")
        return str(int(minimum) if isinstance(minimum, (int, float)) else 0)
    if schema_type == "number":
        minimum = schema.get("minimum")
        if isinstance(minimum, (int, float)):
            return f"{minimum}"
        return "0.0"
    if schema_type == "array":
        items = (
            resolve_schema(schema.get("items", {}), root_schema)
            if isinstance(schema.get("items"), dict)
            else {}
        )
        item_type = schema_type_name(items)
        if item_type == "string":
            return '["value"]'
        if item_type == "integer":
            return "[0]"
        if item_type == "boolean":
            return "[false]"
        return "[]"
    if schema_type == "string":
        return json.dumps("value")
    if schema_type == "object":
        return "{}"
    return json.dumps("value")


def is_object_schema(schema: dict[str, Any]) -> bool:
    schema_type = schema_type_name(schema)
    return schema_type == "object" and (
        isinstance(schema.get("properties"), dict)
        or isinstance(schema.get("additionalProperties"), dict)
    )


def schema_type_name(schema: dict[str, Any]) -> str | None:
    type_value = schema.get("type")
    if isinstance(type_value, list):
        for item in type_value:
            if item != "null":
                return item
        return None
    if isinstance(type_value, str):
        return type_value
    if "properties" in schema:
        return "object"
    return None


def resolve_schema(node: Any, root_schema: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(node, dict):
        return {}

    resolved = dict(node)

    if "$ref" in resolved:
        ref = resolved.pop("$ref")
        target = lookup_ref(root_schema, ref)
        resolved = merge_schema(resolve_schema(target, root_schema), resolved)

    if "allOf" in resolved:
        merged: dict[str, Any] = {}
        for item in resolved.pop("allOf"):
            merged = merge_schema(merged, resolve_schema(item, root_schema))
        resolved = merge_schema(merged, resolved)

    return resolved


def merge_schema(base: dict[str, Any], extra: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in extra.items():
        if key == "properties" and isinstance(value, dict):
            merged[key] = {**merged.get(key, {}), **value}
        elif key == "required" and isinstance(value, list):
            merged[key] = list(dict.fromkeys([*merged.get(key, []), *value]))
        elif key == "definitions" and isinstance(value, dict):
            merged[key] = {**merged.get(key, {}), **value}
        else:
            merged[key] = value
    return merged


def lookup_ref(root_schema: dict[str, Any], ref: str) -> Any:
    if not ref.startswith("#/"):
        raise ValueError(f"unsupported schema ref: {ref}")
    current: Any = root_schema
    for key in ref[2:].split("/"):
        current = current[key]
    return current


if __name__ == "__main__":
    raise SystemExit(main())
