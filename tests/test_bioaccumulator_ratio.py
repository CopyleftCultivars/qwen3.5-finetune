from __future__ import annotations

import unittest
from contextlib import contextmanager
from unittest.mock import patch

from rlm_slice.domain_tools import bioaccumulator_ratio, _parse_range


_CROP = {
    "Crop": "Test Crop",
    "Scientific Name": "Testus cropus",
    "NPK Requirements": {"Phosphorus": "30-70", "Potassium": "40-140"},
}
_PLANT = {
    "common_name": "Test Plant",
    "scientific_name": "Testus plantus",
    "parts": {
        "leaf": {
            "minerals": {
                "phosphorus": {"min": 100, "max": 200},
                "potassium": {"min": 200, "max": 400},
            }
        },
        "root": {
            "minerals": {
                "phosphorus": {"min": 300, "max": 500},
                "potassium": {"min": 600, "max": 800},
            }
        },
        "seed": {
            "minerals": {
                "phosphorus": {"max": 100000},
                "potassium": {"min": 100000},
            }
        },
        "invalid_part": None,
    },
}


@contextmanager
def _loaded(crop: dict, plant: dict):
    with patch("rlm_slice.domain_tools.load_crop_requirements", return_value=[crop]), patch(
        "rlm_slice.domain_tools.load_plant_mineral_profiles", return_value=[plant]
    ):
        yield


class BioaccumulatorRatioTests(unittest.TestCase):
    def test_real_data_corn_and_okra_matches_hand_calculated_golden(self):
        # Okra P midpoint = (630 + 6300) / 2 = 3465; Corn P midpoint = 50.
        # Okra K midpoint = (2200 + 32500) / 2 = 17350; Corn K midpoint = 90.
        result = bioaccumulator_ratio("Corn", "Okra")

        self.assertEqual(
            result["ratios_ppm_per_requirement_unit"],
            {"phosphorus": 69.3, "potassium": 192.778},
        )
        self.assertEqual(result["not_comparable"], ["nitrogen"])
        self.assertIn("relative signal", result["unit_caveat"])
        self.assertIn("not a unit-equivalent dosing calculation", result["unit_caveat"])

    def test_richest_complete_part_wins_and_one_sided_ranges_are_skipped(self):
        with _loaded(_CROP, _PLANT):
            result = bioaccumulator_ratio("Test Crop", "Test Plant")

        # Root midpoints (P=400, K=700) beat leaf values. Incomplete seed
        # values and the malformed part are ignored.
        self.assertEqual(
            result["ratios_ppm_per_requirement_unit"],
            {"phosphorus": 8.0, "potassium": 7.778},
        )
        self.assertEqual(result["not_comparable"], ["nitrogen"])

    def test_zero_crop_midpoint_is_not_comparable(self):
        crop = {
            **_CROP,
            "NPK Requirements": {"Phosphorus": "0-0", "Potassium": "40-140"},
        }
        with _loaded(crop, _PLANT):
            result = bioaccumulator_ratio("Test Crop", "Test Plant")

        self.assertEqual(result["ratios_ppm_per_requirement_unit"], {"potassium": 7.778})
        self.assertEqual(result["not_comparable"], ["phosphorus", "nitrogen"])

    def test_missing_or_malformed_profile_parts_are_not_comparable(self):
        plant = {**_PLANT, "parts": None}
        with _loaded(_CROP, plant):
            result = bioaccumulator_ratio("Test Crop", "Test Plant")

        self.assertEqual(result["ratios_ppm_per_requirement_unit"], {})
        self.assertEqual(
            result["not_comparable"],
            ["phosphorus", "potassium", "nitrogen"],
        )

    def test_missing_nutrient_data_only_marks_that_nutrient_not_comparable(self):
        plant = {
            **_PLANT,
            "parts": {
                "leaf": {
                    "minerals": {
                        "phosphorus": {"min": 100, "max": 200},
                        "potassium": {"max": 100000},
                    }
                }
            },
        }
        with _loaded(_CROP, plant):
            result = bioaccumulator_ratio("Test Crop", "Test Plant")

        self.assertEqual(result["ratios_ppm_per_requirement_unit"], {"phosphorus": 3.0})
        self.assertEqual(result["not_comparable"], ["potassium", "nitrogen"])

    def test_scientific_names_and_single_value_crop_ranges_work(self):
        result = bioaccumulator_ratio("Zea mays", "Abelmoschus esculentus")
        self.assertEqual((result["crop"], result["candidate_plant"]), ("Corn", "Okra"))

        anise = bioaccumulator_ratio("Anise", "Garlic")
        self.assertEqual(
            anise["ratios_ppm_per_requirement_unit"],
            {"phosphorus": 76.375, "potassium": 226.925},
        )

    def test_blank_names_do_not_fall_through_to_first_database_row(self):
        self.assertIn("error", bioaccumulator_ratio("  ", "Okra"))
        self.assertIn("error", bioaccumulator_ratio("Corn", "  "))

    def test_unknown_crop_and_plant_return_specific_errors(self):
        crop_error = bioaccumulator_ratio("Not A Real Crop Zzz", "Okra")
        plant_error = bioaccumulator_ratio("Corn", "Not A Real Plant Zzz")
        self.assertIn("no crop matching", crop_error["error"])
        self.assertIn("no plant matching", plant_error["error"])


class BioaccumulatorRangeTests(unittest.TestCase):
    def test_range_separator_is_not_treated_as_a_negative_sign(self):
        self.assertEqual(_parse_range("30-70"), (30.0, 70.0))

    def test_single_value_and_decimal_ranges_are_supported(self):
        self.assertEqual(_parse_range("40"), (40.0, 40.0))
        self.assertEqual(_parse_range("2.5-3.5"), (2.5, 3.5))

    def test_text_without_numbers_is_unavailable(self):
        self.assertIsNone(_parse_range("not available"))


if __name__ == "__main__":
    unittest.main()
