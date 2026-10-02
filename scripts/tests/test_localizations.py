"""Guard localization coverage and formatting across the supported app languages."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "localization_check", Path(__file__).parents[1] / "check-localizations.py"
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationTests(unittest.TestCase):
    def test_precision_and_template_variables_are_checked(self):
        source = "%.2f seconds, {sourceName}_${videos}, %lld%%"
        self.assertNotEqual(CHECK.placeholders(source), CHECK.placeholders(source.replace("%.2f", "%.1f")))
        self.assertNotEqual(CHECK.placeholders(source), CHECK.placeholders(source.replace("{sourceName}", "{date}")))

    def test_positional_arguments_can_be_reordered(self):
        self.assertEqual(CHECK.format_arguments("%@ %lld"), CHECK.format_arguments("%2$lld %1$@"))
        self.assertNotEqual(CHECK.format_arguments("%@ %lld"), CHECK.format_arguments("%1$lld %2$@"))

    def test_literal_percent_in_prose_is_not_a_format_argument(self):
        self.assertEqual(CHECK.placeholders("99%+ for subtitles and 50% larger files"), {})

    def test_missing_translations_fail_but_intentional_tokens_are_exempt(self):
        strings = {"Save": {}, "{sourceName}": {"shouldTranslate": False}}
        self.assertEqual(CHECK.locale_errors(strings, "de"), ["de: missing translation for 'Save'"])

    def test_symbolic_keys_use_english_values_for_format_validation(self):
        strings = {"DESCRIPTION": {"localizations": {"en": unit("Value: %.2f"), "fr": unit("Valeur : %.2f")}}}
        self.assertEqual(CHECK.locale_errors(strings, "fr"), [])
        strings["DESCRIPTION"]["localizations"]["fr"] = unit("Valeur : %lld")
        self.assertTrue(CHECK.locale_errors(strings, "fr"))

    def test_plural_requirements_follow_the_target_language(self):
        english = {"variations": {"plural": {"one": unit("%lld clip"), "other": unit("%lld clips")}}}
        strings = {"%lld clips": {"localizations": {
            "en": english,
            "ja": {"variations": {"plural": {"other": unit("%lld本のクリップ")}}},
            "de": {"variations": {"plural": {"other": unit("%lld Clips")}}},
        }}}
        self.assertEqual(CHECK.locale_errors(strings, "ja"), [])
        self.assertTrue(CHECK.locale_errors(strings, "de"))
        strings["%lld clips"]["localizations"]["de"]["variations"]["plural"]["one"] = unit("%lld Clip")
        self.assertEqual(CHECK.locale_errors(strings, "de"), [])

    def test_empty_translations_are_rejected(self):
        strings = {"Save": {"localizations": {"de": unit(" ")}}}
        self.assertTrue(CHECK.locale_errors(strings, "de"))


if __name__ == "__main__":
    unittest.main()
