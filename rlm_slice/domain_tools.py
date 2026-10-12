"""Domain tool functions for the multi-tool epic (#172), built per #174.

Three tools:

  * `bioaccumulator_ratio` -- pure calculation, no lookup ambiguity.
  * `regional_recipe_lookup` -- combined region + recipe/technique lookup,
    enriched with a supplementary QMD collection lookup where possible.
  * `local_fertilizer_plants` -- the full natural-fertilizer-recipe chain in
    one call (qwen3.5-finetune #9): given a location and an NPK target, find
    locally-growing plants, cross-reference their mineral profiles, blend the
    best candidates toward the target ratio, and return a complete fermented
    wildcrafted fertilizer recipe. A faithful Python port of
    `natural_farming_chat/lib/services/fertilizer_formulation_service.dart`'s
    `formulate()` (the harness-orchestrated design, chainlink qwen3.5-finetune
    #1: the model's job is to recognize the request and supply location +
    nutrient target in one tool call; every subsequent step -- region lookup,
    per-plant NPK cross-reference, blend ratio, recipe formatting -- happens
    here, deterministically, not across further model-initiated tool calls).
    Ported rather than shared code because the two region-data JSON schemas
    differ (Dart's bundled asset has separate Country/Region fields; this
    project's copy of local_plants_by_region.json has a single Location
    string per entry, the same file regional_recipe_lookup above already
    matches against) -- the *algorithm* is ported faithfully, the region-
    matching step is adapted to the schema this data actually has.

Each tool is exposed two ways:
  * as a plain Python callable, for GPU-side use inside rlm_arm.py's
    `custom_tools` REPL-exposure pattern (see `agronomy_tools()`);
  * as a Cactus-shaped `ToolFunction` dict (`{"name", "description",
    "parameters"}` -- see cactus-sdk/python/cactus/server.py's `ToolFunction`
    and cactus-engine/src/rag.cpp's `tool_to_text()`, which embeds exactly
    `name + " " + description` for `select_relevant_tools` to score against)
    via `TOOL_DEFINITIONS`, so the same definitions can be registered
    on-device later without redefinition (#177).
"""

from __future__ import annotations

import re
from typing import Any

from rlm_slice.domain_data import (
    load_crop_requirements,
    load_enriched_recipes,
    load_local_plants_by_region,
    load_plant_mineral_profiles,
)
from rlm_slice.retrieval import retrieve

# No leading "-?": crop_requirements.json's NPK ranges are strings like
# "30-70", where the hyphen is a range separator, not a sign. A leading `-?`
# here misparses "30-70" as [30, -70] (findall matches "30", then treats the
# separator's "-" as a unary minus on "70") -- discovered via #175's dual-
# relevant eval construction, where every generated ratio came out negative.
_RANGE_RE = re.compile(r"\d+(?:\.\d+)?")

# plant_mineral_profiles.json tracks trace minerals (P, K, Ca, Fe, ...) per
# USDA composition data; it does not track nitrogen (N is protein-bound, not
# a "mineral" in that dataset's sense). So only P and K are ever comparable
# against crop_requirements.json's NPK Requirements -- nitrogen is always
# reported as not-comparable, not silently dropped.
_NUTRIENT_MAP = {"Phosphorus": "phosphorus", "Potassium": "potassium"}

_PROBLEM_NUTRIENT_HINTS = {
    "nitrogen": "N", "n deficiency": "N",
    "phosphorus": "P", "p deficiency": "P",
    "potassium": "K", "k deficiency": "K",
}

# NPK target ratios by use case, ported verbatim from fertilizer_formulation_
# service.dart's `npkTargets` (values are relative proportions, not absolute
# percentages -- FORMULATION_GUIDE.md is the original source).
NPK_TARGETS: dict[str, dict[str, Any]] = {
    "nitrogen": {"name": "High Nitrogen", "description": "Best for leafy greens, vegetative growth stage", "n": 10, "p": 5, "k": 5},
    "phosphorus": {"name": "High Phosphorus", "description": "Best for root development, flowering, seedlings", "n": 5, "p": 10, "k": 10},
    "potassium": {"name": "High Potassium", "description": "Best for fruiting, disease resistance, late season", "n": 5, "p": 5, "k": 10},
    "balanced": {"name": "Balanced", "description": "General purpose, most crops", "n": 5, "p": 5, "k": 5},
    "vegetative": {"name": "Vegetative Stage", "description": "Early growth, leaf and stem development", "n": 10, "p": 5, "k": 5},
    "flowering": {"name": "Flowering Stage", "description": "Flower bud formation and bloom", "n": 5, "p": 10, "k": 10},
    "fruiting": {"name": "Fruiting Stage", "description": "Fruit development and ripening", "n": 5, "p": 5, "k": 10},
    "seedling": {"name": "Seedling Stage", "description": "Root establishment after transplant", "n": 10, "p": 20, "k": 10},
}

_BLEND_PERCENTAGES = {2: [60, 40], 3: [45, 30, 25], 4: [40, 25, 20, 15], 5: [35, 25, 20, 12, 8]}

_PLANT_STRING_RE = re.compile(r"^(.+?)\s*\(([^)]+)\)$")


def _npk_ratio_normalized(target: dict[str, Any]) -> tuple[float, float, float]:
    total = target["n"] + target["p"] + target["k"]
    if total == 0:
        return (0.0, 0.0, 0.0)
    return (target["n"] / total, target["p"] / total, target["k"] / total)


def _parse_plant_string(raw: str) -> tuple[str, str]:
    """Parse "Genus species (Common Name)" -> (scientific_name, common_name).

    Falls back to using the whole string as both when there's no parenthetical
    common name -- same graceful degradation as Dart's `_parsePlantString`.
    """
    match = _PLANT_STRING_RE.match(raw.strip())
    if match:
        return match.group(1).strip(), match.group(2).strip()
    return raw.strip(), raw.strip()


def _match_plant_profile(scientific_name: str, sci_index: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """Match a region plant's scientific name to the mineral-profile database.

    Same four strategies as Dart's `_matchPlantProfile`, in the same order:
    exact, prefix ("allium sativum" matches "allium sativum var. sativum"),
    reverse-prefix (the query is the more specific one), and a genus match
    for "spp." entries ("rubus spp." -> any "rubus *").
    """
    query = scientific_name.lower().strip()

    if query in sci_index:
        return sci_index[query]

    for key, value in sci_index.items():
        if key.startswith(query):
            return value

    for key, value in sci_index.items():
        if query.startswith(key):
            return value

    if query.endswith(" spp.") or query.endswith(" spp"):
        genus = query.split(" ")[0]
        for key, value in sci_index.items():
            if key.startswith(f"{genus} "):
                return value

    return None


def _extract_mineral_mid(minerals: dict[str, Any], name: str) -> float:
    """Average concentration in ppm: midpoint of min/max, or whichever is present."""
    data = minerals.get(name)
    if not data:
        return 0.0
    lo, hi = data.get("min"), data.get("max")
    if lo is not None and hi is not None:
        return (float(lo) + float(hi)) / 2.0
    if hi is not None:
        return float(hi)
    if lo is not None:
        return float(lo)
    return 0.0


def _target_score(npk: tuple[float, float, float], ratio: tuple[float, float, float]) -> float:
    """Weighted sum emphasizing the target's dominant nutrient(s), same as Dart's `_targetScore`."""
    return npk[0] * ratio[0] + npk[1] * ratio[1] + npk[2] * ratio[2]


def _parse_range(text: str) -> tuple[float, float] | None:
    nums = [float(n) for n in _RANGE_RE.findall(str(text))]
    if not nums:
        return None
    return (min(nums), max(nums))


def _mid(bounds: tuple[float, float]) -> float:
    return (bounds[0] + bounds[1]) / 2.0


def _find_crop(name: str) -> dict[str, Any] | None:
    name_l = name.strip().lower()
    if not name_l:
        return None
    rows = load_crop_requirements()
    for row in rows:
        if str(row.get("Crop", "")).lower() == name_l or str(row.get("Scientific Name", "")).lower() == name_l:
            return row
    for row in rows:
        if name_l in str(row.get("Crop", "")).lower():
            return row
    return None


def _find_plant(name: str) -> dict[str, Any] | None:
    name_l = name.strip().lower()
    if not name_l:
        return None
    rows = load_plant_mineral_profiles()
    for row in rows:
        if str(row.get("common_name", "")).lower() == name_l or str(row.get("scientific_name", "")).lower() == name_l:
            return row
    for row in rows:
        if name_l in str(row.get("common_name", "")).lower() or name_l in str(row.get("scientific_name", "")).lower():
            return row
    return None


def _best_mineral_mid(plant_row: dict[str, Any], mineral_key: str) -> float | None:
    """Richest-part mid-range value for one mineral, ppm (max across plant parts)."""
    parts = plant_row.get("parts")
    if not isinstance(parts, dict):
        return None

    best: float | None = None
    for part_data in parts.values():
        if not isinstance(part_data, dict):
            continue
        minerals = part_data.get("minerals")
        if not isinstance(minerals, dict):
            continue
        mineral = minerals.get(mineral_key)
        if not isinstance(mineral, dict):
            continue
        try:
            mid = (float(mineral["min"]) + float(mineral["max"])) / 2.0
        except (KeyError, TypeError, ValueError):
            continue
        if best is None or mid > best:
            best = mid
    return best


def bioaccumulator_ratio(crop: str, candidate_plant: str) -> dict[str, Any]:
    """Compare a crop's NPK requirement against a candidate bioaccumulator plant's
    tissue mineral content (plant_mineral_profiles.json), one ratio per comparable
    nutrient (plant tissue mid-range ppm / crop mid-range requirement). Nitrogen is
    never comparable -- the mineral-profile source does not track it. Ratios are a
    relative signal for judging whether a plant is nutrient-dense enough, relative
    to the crop's stated need, to be worth cutting as green manure or steeping into
    a liquid feed -- not a calibrated fertilizer dosing formula (the two sources use
    different unit systems: tissue ppm vs. an agronomic NPK requirement index).
    """
    crop_row = _find_crop(crop)
    if crop_row is None:
        return {"error": f"no crop matching {crop!r} in crop_requirements.json"}
    plant_row = _find_plant(candidate_plant)
    if plant_row is None:
        return {"error": f"no plant matching {candidate_plant!r} in plant_mineral_profiles.json"}

    npk = crop_row.get("NPK Requirements")
    if not isinstance(npk, dict):
        npk = {}
    ratios: dict[str, float] = {}
    not_comparable: list[str] = []
    for req_key, mineral_key in _NUTRIENT_MAP.items():
        crop_bounds = _parse_range(npk.get(req_key, ""))
        plant_mid = _best_mineral_mid(plant_row, mineral_key)
        if crop_bounds is None or plant_mid is None:
            not_comparable.append(mineral_key)
            continue
        crop_mid = _mid(crop_bounds)
        if crop_mid == 0:
            not_comparable.append(mineral_key)
            continue
        ratios[mineral_key] = round(plant_mid / crop_mid, 3)
    not_comparable.append("nitrogen")  # never tracked by the mineral-profile source

    return {
        "crop": crop_row.get("Crop"),
        "candidate_plant": plant_row.get("common_name") or plant_row.get("scientific_name"),
        "ratios_ppm_per_requirement_unit": ratios,
        "not_comparable": not_comparable,
        "unit_caveat": (
            "ratios compare tissue ppm (plant_mineral_profiles.json) against an "
            "agronomic NPK requirement index (crop_requirements.json) -- a relative "
            "signal, not a unit-equivalent dosing calculation"
        ),
    }


def _token_overlap_score(query_terms: set[str], *texts: str) -> int:
    blob = " ".join(texts).lower()
    return sum(1 for term in query_terms if term and term in blob)


def regional_recipe_lookup(
    crop: str | None = None,
    region: str | None = None,
    problem: str | None = None,
    use_qmd: bool = True,
    qmd_k: int = 3,
) -> dict[str, Any]:
    """Look up candidate bioaccumulator plants native to a region
    (local_plants_by_region.json) and/or matching Korean Natural Farming (KNF) /
    JADAM technique or recipe for a crop or stated problem (enriched_recipes.json),
    combining structured lookups with a supplementary QMD collection search so the
    result surfaces both known structured facts and any related indexed reference
    material in one call. At least one of crop, region, or problem must be given.
    """
    if not (crop or region or problem):
        return {"error": "at least one of crop, region, or problem is required"}

    region_l = region.strip().lower() if region else None
    crop_l = crop.strip().lower() if crop else None

    region_matches = []
    regions_growing_crop = []
    for row in load_local_plants_by_region():
        location = str(row.get("Location", ""))
        plants = row.get("Plants", [])
        if region_l and region_l in location.lower():
            region_matches.append(row)
        if crop_l and any(crop_l in str(p).lower() for p in plants):
            regions_growing_crop.append(location)

    query_terms = {t.lower() for t in (crop, problem) if t}
    hinted_nutrient = None
    if problem:
        for hint, code in _PROBLEM_NUTRIENT_HINTS.items():
            if hint in problem.lower():
                hinted_nutrient = code
                break

    scored_recipes = []
    for recipe in load_enriched_recipes():
        score = _token_overlap_score(
            query_terms,
            str(recipe.get("recipe_name", "")),
            " ".join(recipe.get("suggested_bioaccumulators", [])),
            " ".join(recipe.get("ingredients", [])),
        )
        if hinted_nutrient and recipe.get("primary_nutrient") == hinted_nutrient:
            score += 2
        if score > 0:
            scored_recipes.append((score, recipe))
    scored_recipes.sort(key=lambda pair: pair[0], reverse=True)
    matching_recipes = [r for _score, r in scored_recipes[:5]]

    qmd_context = "qmd lookup skipped (use_qmd=False)"
    if use_qmd:
        qmd_query = " ".join(t for t in (crop, region, problem) if t).strip()
        if qmd_query:
            result = retrieve(qmd_query, k=qmd_k)
            qmd_context = result.as_context()
        else:
            qmd_context = "qmd lookup skipped (empty query)"

    return {
        "region_matches": region_matches,
        "regions_growing_crop": regions_growing_crop,
        "matching_recipes": matching_recipes,
        "qmd_context": qmd_context,
    }


def local_fertilizer_plants(location: str, nutrient: str) -> dict[str, Any]:
    """Create a complete natural-fertilizer recipe for a location and NPK target:
    find locally-growing plants (local_plants_by_region.json), cross-reference
    their mineral profiles (plant_mineral_profiles.json) against the requested
    NPK target, blend the best 2-5 candidates toward that ratio, and return the
    full fermented wildcrafted fertilizer preparation. One call covers the
    whole chain -- region lookup, per-plant NPK comparison, and recipe
    formulation -- so the model only needs to supply location and nutrient,
    not drive each step itself.
    """
    target = NPK_TARGETS.get(nutrient.lower())
    if target is None:
        return {
            "error": f'unknown nutrient target {nutrient!r}; valid options: {", ".join(NPK_TARGETS)}',
        }

    location_l = location.strip().lower()
    matched_locations: list[str] = []
    region_plant_strings: set[str] = set()
    for row in load_local_plants_by_region():
        row_location = str(row.get("Location", ""))
        row_location_l = row_location.lower()
        if location_l and (location_l in row_location_l or row_location_l in location_l):
            matched_locations.append(row_location)
            region_plant_strings.update(row.get("Plants", []))

    if not matched_locations:
        return {"error": f'no region found matching {location!r}'}

    sci_index = {str(row.get("scientific_name", "")).lower(): row for row in load_plant_mineral_profiles()}

    ratio = _npk_ratio_normalized(target)
    candidates: list[dict[str, Any]] = []  # one entry per (plant, part) with measurable NPK
    for plant_string in region_plant_strings:
        scientific_name, common_name = _parse_plant_string(plant_string)
        profile = _match_plant_profile(scientific_name, sci_index)
        if profile is None:
            continue
        for part_name, part_data in profile.get("parts", {}).items():
            minerals = part_data.get("minerals", {})
            npk = (
                _extract_mineral_mid(minerals, "nitrogen"),
                _extract_mineral_mid(minerals, "phosphorus"),
                _extract_mineral_mid(minerals, "potassium"),
            )
            if any(npk):
                candidates.append(
                    {
                        "common_name": profile.get("common_name") or common_name,
                        "scientific_name": profile.get("scientific_name") or scientific_name,
                        "part": part_name,
                        "npk_ppm": npk,
                    }
                )

    if not candidates:
        return {
            "error": (
                f"found {len(region_plant_strings)} plants in {location!r} "
                "but none have NPK data in the mineral profiles database"
            )
        }

    # Best part per plant (highest target-weighted score), then overall rank.
    best_by_plant: dict[str, dict[str, Any]] = {}
    for c in candidates:
        key = c["scientific_name"].lower()
        if key not in best_by_plant or _target_score(c["npk_ppm"], ratio) > _target_score(
            best_by_plant[key]["npk_ppm"], ratio
        ):
            best_by_plant[key] = c
    ranked = sorted(best_by_plant.values(), key=lambda c: _target_score(c["npk_ppm"], ratio), reverse=True)

    if len(ranked) < 2:
        return {"error": f"only {len(ranked)} plant(s) with NPK data found in {location!r}; need at least 2 to blend"}

    count = min(max(len(ranked), 2), 5)
    selected = ranked[:count]
    percentages = _BLEND_PERCENTAGES[count]

    ingredients = []
    total_n = total_p = total_k = 0.0
    for plant, pct in zip(selected, percentages):
        frac = pct / 100.0
        # PPM to dry-weight percentage: 10000 ppm = 1%, matching Dart's
        # _PlantNpk.nPercent/pPercent/kPercent convention.
        n_contrib = (plant["npk_ppm"][0] / 10000.0) * frac
        p_contrib = (plant["npk_ppm"][1] / 10000.0) * frac
        k_contrib = (plant["npk_ppm"][2] / 10000.0) * frac
        total_n += n_contrib
        total_p += p_contrib
        total_k += k_contrib
        ingredients.append(
            {
                "common_name": plant["common_name"],
                "scientific_name": plant["scientific_name"],
                "part_used": plant["part"],
                "percentage": pct,
                "n_contribution": round(n_contrib, 6),
                "p_contribution": round(p_contrib, 6),
                "k_contribution": round(k_contrib, 6),
            }
        )

    total_sum = total_n + total_p + total_k
    if total_sum > 0:
        actual_ratio = (total_n / total_sum, total_p / total_sum, total_k / total_sum)
        dot = sum(a * b for a, b in zip(actual_ratio, ratio))
        mag = (sum(a * a for a in actual_ratio) ** 0.5) * (sum(b * b for b in ratio) ** 0.5)
        match_score = round((dot / mag) * 100, 1) if mag > 0 else 0.0
    else:
        match_score = 0.0

    region_name = "; ".join(dict.fromkeys(matched_locations))  # dedupe, preserve order
    n_pct, p_pct, k_pct = target["n"], target["p"], target["k"]
    recipe_lines = [
        f"Formulation: {target['name']} Blend for {region_name}",
        f"Target NPK Ratio: {n_pct:.0f}-{p_pct:.0f}-{k_pct:.0f}",
        f"Best for: {target['description']}",
        "",
        "Ingredients:",
    ]
    for ing in ingredients:
        recipe_lines.append(
            f"  {ing['percentage']}% {ing['common_name']} ({ing['part_used']}) "
            f"- N: {ing['n_contribution'] * 100:.2f}%, "
            f"P: {ing['p_contribution'] * 100:.2f}%, "
            f"K: {ing['k_contribution'] * 100:.2f}%"
        )
    recipe_lines += [
        "",
        f"Estimated Blend NPK: {total_n * 100:.2f}-{total_p * 100:.2f}-{total_k * 100:.2f}",
        f"NPK Match Score: {match_score:.0f}%",
        "",
        "Preparation (Fermented Wildcrafted Plant Fertilizer):",
        "1. Collect and finely chop the selected plants.",
        "2. Mix with brown sugar or molasses (optional) to start fermentation.",
        "3. Add LAB serum and IMO4 if available.",
        "4. Add non-chlorinated water to create a slurry.",
        "5. Cover with breathable cloth, ferment 7-14 days in cool dark place.",
        "6. Dilute 1:10 with water and apply as soil drench or foliar spray.",
        "",
        "Application Rate: 2-4 lbs dry material per 100 sq ft.",
        "Note: Start with lower rates and monitor plant response.",
    ]

    return {
        "region_name": region_name,
        "target_name": target["name"],
        "target_npk_ratio": f"{n_pct:.0f}-{p_pct:.0f}-{k_pct:.0f}",
        "ingredients": ingredients,
        "total_npk": {"n": round(total_n, 6), "p": round(total_p, 6), "k": round(total_k, 6)},
        "match_score_pct": match_score,
        "recipe_text": "\n".join(recipe_lines),
    }


TOOL_DEFINITIONS: list[dict[str, Any]] = [
    {
        "name": "bioaccumulator_ratio",
        "description": bioaccumulator_ratio.__doc__.strip(),
        "parameters": {
            "type": "object",
            "properties": {
                "crop": {"type": "string", "description": "Crop name, e.g. 'Corn'"},
                "candidate_plant": {
                    "type": "string",
                    "description": "Candidate bioaccumulator plant common or scientific name, e.g. 'Comfrey'",
                },
            },
            "required": ["crop", "candidate_plant"],
        },
    },
    {
        "name": "regional_recipe_lookup",
        "description": regional_recipe_lookup.__doc__.strip(),
        "parameters": {
            "type": "object",
            "properties": {
                "crop": {"type": "string", "description": "Crop name, optional"},
                "region": {"type": "string", "description": "Region or location name, optional"},
                "problem": {"type": "string", "description": "Stated problem, e.g. 'nitrogen deficiency', optional"},
            },
            "required": [],
        },
    },
    {
        "name": "local_fertilizer_plants",
        "description": local_fertilizer_plants.__doc__.strip(),
        "parameters": {
            "type": "object",
            "properties": {
                "location": {"type": "string", "description": "Country or region name, e.g. 'Kenya', 'California'"},
                "nutrient": {
                    "type": "string",
                    "description": f"Target nutrient or growth stage: {', '.join(NPK_TARGETS)}",
                },
            },
            "required": ["location", "nutrient"],
        },
    },
]

TOOL_REGISTRY: dict[str, Any] = {
    "bioaccumulator_ratio": bioaccumulator_ratio,
    "regional_recipe_lookup": regional_recipe_lookup,
    "local_fertilizer_plants": local_fertilizer_plants,
}


def domain_tools() -> dict[str, Any]:
    """rlm_arm.py-style custom_tools dict, matching agronomy_tools()'s shape."""
    return dict(TOOL_REGISTRY)
