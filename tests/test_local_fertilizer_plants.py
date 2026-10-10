from __future__ import annotations

import unittest
from unittest.mock import patch

from rlm_slice.domain_tools import (
    NPK_TARGETS,
    _match_plant_profile,
    _parse_plant_string,
    local_fertilizer_plants,
)

_REGIONS = [
    {
        "Location": "Testland",
        "Plants": [
            "Zea mays (Corn)",
            "Symphytum officinale (Comfrey)",
            "Medicago sativa (Alfalfa)",
            "No Parenthetical Plant",
        ],
    },
    {
        "Location": "Other Place",
        "Plants": ["Triticum aestivum (Wheat)"],
    },
]

_PROFILES = [
    {
        "common_name": "Comfrey",
        "scientific_name": "symphytum officinale",
        "parts": {"leaf": {"minerals": {"nitrogen": {"min": 20000, "max": 30000}, "phosphorus": {"min": 2000, "max": 4000}, "potassium": {"min": 30000, "max": 50000}}}},
    },
    {
        "common_name": "Alfalfa",
        "scientific_name": "medicago sativa",
        "parts": {"leaf": {"minerals": {"nitrogen": {"min": 25000, "max": 35000}, "phosphorus": {"min": 3000, "max": 5000}, "potassium": {"min": 20000, "max": 30000}}}},
    },
    {
        # Only one nutrient present -- exercises the "whichever is available" branch.
        "common_name": "Nettle",
        "scientific_name": "urtica dioica var. gracilis",
        "parts": {"whole": {"minerals": {"nitrogen": {"max": 40000}}}},
    },
    {
        # No NPK data at all -- must be excluded from candidates.
        "common_name": "Inert Plant",
        "scientific_name": "zea mays",
        "parts": {"stem": {"minerals": {}}},
    },
]


def _patched():
    return patch.multiple(
        "rlm_slice.domain_tools",
        load_local_plants_by_region=lambda: _REGIONS,
        load_plant_mineral_profiles=lambda: _PROFILES,
    )


class LocalFertilizerPlantsTests(unittest.TestCase):
    def test_happy_path_builds_a_blend_with_recipe_text(self):
        with _patched():
            result = local_fertilizer_plants("Testland", "nitrogen")
        self.assertNotIn("error", result)
        self.assertIn("Testland", result["region_name"])
        self.assertEqual(result["target_name"], NPK_TARGETS["nitrogen"]["name"])
        # Comfrey, Alfalfa, Nettle all have nitrogen data; Zea mays matches
        # "Inert Plant" (no NPK) via reverse-prefix genus match, but "Corn"'s
        # scientific name also exactly matches "zea mays" -- either way it
        # contributes nothing since that profile has no mineral data.
        names = {ing["common_name"] for ing in result["ingredients"]}
        self.assertIn("Comfrey", names)
        self.assertIn("Alfalfa", names)
        self.assertGreaterEqual(len(result["ingredients"]), 2)
        self.assertIn("Preparation (Fermented Wildcrafted Plant Fertilizer):", result["recipe_text"])
        self.assertGreater(result["match_score_pct"], 0)

    def test_percentages_sum_to_100(self):
        with _patched():
            result = local_fertilizer_plants("Testland", "balanced")
        self.assertEqual(sum(ing["percentage"] for ing in result["ingredients"]), 100)

    def test_unknown_nutrient_is_an_error(self):
        with _patched():
            result = local_fertilizer_plants("Testland", "unobtainium")
        self.assertIn("error", result)
        self.assertIn("unobtainium", result["error"])

    def test_no_matching_region_is_an_error(self):
        with _patched():
            result = local_fertilizer_plants("Nowhereland", "nitrogen")
        self.assertIn("error", result)

    def test_region_with_no_npk_candidates_is_an_error(self):
        with patch.multiple(
            "rlm_slice.domain_tools",
            load_local_plants_by_region=lambda: [{"Location": "Barren", "Plants": ["Unknownus plantus (Mystery)"]}],
            load_plant_mineral_profiles=lambda: _PROFILES,
        ):
            result = local_fertilizer_plants("Barren", "nitrogen")
        self.assertIn("error", result)
        self.assertIn("none have NPK data", result["error"])

    def test_only_one_viable_plant_is_an_error(self):
        with patch.multiple(
            "rlm_slice.domain_tools",
            load_local_plants_by_region=lambda: [{"Location": "Lonely", "Plants": ["Symphytum officinale (Comfrey)"]}],
            load_plant_mineral_profiles=lambda: _PROFILES,
        ):
            result = local_fertilizer_plants("Lonely", "nitrogen")
        self.assertIn("error", result)
        self.assertIn("at least 2", result["error"])

    def test_bidirectional_substring_region_match(self):
        # Query is a superstring of the stored Location ("Testland, Region X"
        # vs stored "Testland") -- Dart's findRegions matches both directions.
        with _patched():
            result = local_fertilizer_plants("Testland, Region X", "balanced")
        self.assertNotIn("error", result)


class ParsePlantStringTests(unittest.TestCase):
    def test_parenthetical_form(self):
        self.assertEqual(_parse_plant_string("Zea mays (Corn)"), ("Zea mays", "Corn"))

    def test_no_parenthetical_falls_back_to_whole_string(self):
        self.assertEqual(_parse_plant_string("Just A Name"), ("Just A Name", "Just A Name"))


class MatchPlantProfileTests(unittest.TestCase):
    def setUp(self):
        self.index = {p["scientific_name"]: p for p in _PROFILES}

    def test_exact_match(self):
        self.assertIs(_match_plant_profile("Symphytum officinale", self.index), self.index["symphytum officinale"])

    def test_prefix_match(self):
        # Query is a prefix of a more specific stored name.
        result = _match_plant_profile("urtica dioica", self.index)
        self.assertIs(result, self.index["urtica dioica var. gracilis"])

    def test_reverse_prefix_match(self):
        # Stored name is a prefix of the (more specific) query.
        result = _match_plant_profile("medicago sativa subsp. caerulea", self.index)
        self.assertIs(result, self.index["medicago sativa"])

    def test_genus_spp_match(self):
        result = _match_plant_profile("urtica spp.", self.index)
        self.assertIs(result, self.index["urtica dioica var. gracilis"])

    def test_no_match_returns_none(self):
        self.assertIsNone(_match_plant_profile("nonexistens plantus", self.index))


if __name__ == "__main__":
    unittest.main()
