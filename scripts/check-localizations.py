#!/usr/bin/env python3
"""Validate catalog localization coverage and interpolation placeholders."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = ROOT / "Aagedal Media Converter/Resources/Localizable.xcstrings"
DEFAULT_AUDIT = ROOT / "scripts/localization-audit.json"
MISSING_CATEGORIES = {"intentional-format-token"}
TRANSLATED_CATEGORIES = {"translated-user-interface", "translated-app-intent"}
PLACEHOLDER_PATTERN = re.compile(
    r"%(?:\d+\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|ll|h|l|L|z|j|t)?[diuoxXfFeEgGaAcsp@%]|\$?\{[A-Za-z_][A-Za-z_0-9]*\}"
)
SINGLE_PLURAL_FORM_LOCALES = {"ja", "ko", "zh-Hans"}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--audit", type=Path, default=DEFAULT_AUDIT)
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error


def localized_values(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        string_value = value.get("value")
        if isinstance(string_value, str):
            yield string_value
        for child in value.values():
            yield from localized_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from localized_values(child)


def placeholders(value: str) -> Counter[str]:
    normalized = []
    for match in PLACEHOLDER_PATTERN.findall(value):
        normalized.append(re.sub(r"^%\d+\$", "%", match))
    return Counter(normalized)


def format_arguments(value: str) -> Counter[tuple[int, str]]:
    """Compare argument positions as well as types when a translation reorders them."""
    arguments: Counter[tuple[int, str]] = Counter()
    next_position = 1
    for token in PLACEHOLDER_PATTERN.findall(value):
        if not token.startswith("%") or token == "%%":
            continue
        position = re.match(r"%(\d+)\$", token)
        if position:
            arguments[(int(position[1]), token[position.end():])] += 1
        else:
            arguments[(next_position, token[1:])] += 1
            next_position += 1
    return arguments


def locale_errors(strings: dict[str, Any], locale: str) -> list[str]:
    errors = []
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        localization = entry.get("localizations", {}).get(locale)
        if not isinstance(localization, dict):
            errors.append(f"{locale}: missing translation for {key!r}")
            continue
        english = entry.get("localizations", {}).get("en", {})
        source_plural = english.get("variations", {}).get("plural")
        target_plural = localization.get("variations", {}).get("plural")
        if source_plural:
            required_forms = {"other"} if locale in SINGLE_PLURAL_FORM_LOCALES else {"one", "other"}
            if not isinstance(target_plural, dict) or not required_forms <= set(target_plural):
                errors.append(f"{locale}: {key!r} needs plural forms {sorted(required_forms)}")
        source_value = english.get("stringUnit", {}).get("value", key)
        values = list(localized_values(localization))
        if not values or any(not value.strip() for value in values):
            errors.append(f"{locale}: empty translation for {key!r}")
        for value in values:
            if placeholders(value) != placeholders(source_value) or format_arguments(value) != format_arguments(source_value):
                errors.append(f"{locale}: {key!r} has mismatched placeholders in {value!r}")
    return errors


def main() -> int:
    arguments = parse_arguments()
    try:
        catalog = load_json(arguments.catalog)
        audit = load_json(arguments.audit)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    errors: list[str] = []
    locale = audit.get("locale")
    strings = catalog.get("strings")
    classifications = audit.get("classifications")
    if not isinstance(locale, str) or not isinstance(strings, dict) or not isinstance(classifications, dict):
        print("error: catalog or audit file has an invalid top-level structure", file=sys.stderr)
        return 1

    expected_categories = MISSING_CATEGORIES | TRANSLATED_CATEGORIES
    unknown_categories = set(classifications) - expected_categories
    missing_categories = expected_categories - set(classifications)
    if unknown_categories:
        errors.append(f"unknown audit categories: {', '.join(sorted(unknown_categories))}")
    if missing_categories:
        errors.append(f"missing audit categories: {', '.join(sorted(missing_categories))}")

    classified: dict[str, str] = {}
    for category, keys in classifications.items():
        if not isinstance(keys, list) or not all(isinstance(key, str) for key in keys):
            errors.append(f"classification {category!r} must be an array of strings")
            continue
        for key in keys:
            previous = classified.get(key)
            if previous is not None:
                errors.append(f"{key!r} is classified as both {previous!r} and {category!r}")
            classified[key] = category

    catalog_keys = set(strings)
    stale_keys = set(classified) - catalog_keys
    if stale_keys:
        errors.append("classified keys absent from catalog: " + ", ".join(repr(key) for key in sorted(stale_keys)))

    missing_locale = {
        key
        for key, entry in strings.items()
        if locale not in entry.get("localizations", {})
    }
    expected_missing = {
        key for key, category in classified.items() if category in MISSING_CATEGORIES
    }
    unclassified = missing_locale - expected_missing
    unexpectedly_missing = expected_missing - missing_locale
    if unclassified:
        errors.append(
            f"{len(unclassified)} unclassified keys are missing {locale}: "
            + ", ".join(repr(key) for key in sorted(unclassified))
        )
    if unexpectedly_missing:
        errors.append(
            "translated keys still classified as missing: "
            + ", ".join(repr(key) for key in sorted(unexpectedly_missing))
        )

    translated_expected = {
        key for key, category in classified.items() if category in TRANSLATED_CATEGORIES
    }
    translated_missing = translated_expected & missing_locale
    if translated_missing:
        errors.append(
            "expected translated keys are missing: "
            + ", ".join(repr(key) for key in sorted(translated_missing))
        )

    intentional_keys = set(classifications.get("intentional-format-token", []))
    invalid_intentional = {
        key
        for key in intentional_keys & catalog_keys
        if strings[key].get("shouldTranslate") is not False
    }
    if invalid_intentional:
        errors.append(
            "intentional tokens must set shouldTranslate=false: "
            + ", ".join(repr(key) for key in sorted(invalid_intentional))
        )

    exceptions = audit.get("placeholderExceptions", {})
    if not isinstance(exceptions, dict) or not all(
        isinstance(key, str) and isinstance(reason, str) and reason.strip()
        for key, reason in exceptions.items()
    ):
        errors.append("placeholderExceptions must map catalog keys to non-empty reasons")
        exceptions = {}
    for key in set(exceptions) - catalog_keys:
        errors.append(f"placeholder exception {key!r} is absent from the catalog")

    for key, entry in strings.items():
        localization = entry.get("localizations", {}).get(locale)
        if localization is None or key in exceptions:
            continue
        source_placeholders = placeholders(key)
        for localized_value in localized_values(localization):
            localized_placeholders = placeholders(localized_value)
            if localized_placeholders != source_placeholders:
                errors.append(
                    f"{key!r}: expected {dict(source_placeholders)}, "
                    f"found {dict(localized_placeholders)} in {localized_value!r}"
                )

    additional_locales = audit.get("additionalLocales", [])
    if not isinstance(additional_locales, list) or not all(isinstance(item, str) for item in additional_locales):
        errors.append("additionalLocales must be an array of locale identifiers")
        additional_locales = []
    for additional_locale in additional_locales:
        errors.extend(locale_errors(strings, additional_locale))
        missing_count = sum(
            entry.get("shouldTranslate") is not False
            and additional_locale not in entry.get("localizations", {})
            for entry in strings.values()
        )
        print(f"{additional_locale} catalog audit: {len(strings)} total, {missing_count} missing translatable keys")

    counts = Counter(classified.values())
    print(
        f"{locale} catalog audit: {len(strings)} total, {len(missing_locale)} missing; "
        f"{counts['intentional-format-token']} intentional tokens, "
        f"{counts['translated-app-intent']} App Intent strings translated, "
        f"{counts['translated-user-interface']} UI strings translated"
    )
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("Localization audit passed: no unclassified missing keys or placeholder mismatches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
