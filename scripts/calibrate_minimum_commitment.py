#!/usr/bin/env python3
"""Calibrate Thermal.csv Minimum_Commitment values to provincial heat capacity.

The statistics input is a CSV with columns ``地区`` and
``供热容量（万千瓦）``. Blank statistical values are treated as zero. The
calibration priority is:

    small -> naturalgas -> subcritical -> supercritical -> ultrasupercritical

Within each province, complete technology classes receive 1, the boundary
class receives a value in [0, 1], and subsequent classes receive 0.
Resources assigned to model zones greater than 33 are outside the 31-province
calibration scope: they are excluded from provincial totals and always receive
``Minimum_Commitment = 0``.
"""

from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path


TECHNOLOGY_PRIORITY = (
    "small",
    "naturalgas",
    "subcritical",
    "supercritical",
    "ultrasupercritical",
)

STAT_PROVINCE_TO_KEY = {
    "北京": "beijing",
    "天津": "tianjin",
    "河北": "hebei",
    "山西": "shanxi",
    "内蒙古": "neimenggu",
    "辽宁": "liaoning",
    "吉林": "jilin",
    "黑龙江": "heilongjiang",
    "上海": "shanghai",
    "江苏": "jiangsu",
    "浙江": "zhejiang",
    "安徽": "anhui",
    "福建": "fujian",
    "江西": "jiangxi",
    "山东": "shandong",
    "河南": "henan",
    "湖北": "hubei",
    "湖南": "hunan",
    "广东": "guangdong",
    "广西": "guangxi",
    "海南": "hainan",
    "重庆": "chongqing",
    "四川": "sichuan",
    "贵州": "guizhou",
    "云南": "yunnan",
    "西藏": "xizang",
    "陕西": "shaanxi",
    "甘肃": "gansu",
    "青海": "qinghai",
    "宁夏": "ningxia",
    "新疆": "xinjiang",
}
KEY_TO_STAT_PROVINCE = {value: key for key, value in STAT_PROVINCE_TO_KEY.items()}

# Model regions within the 31-province scope that require an explicit mapping.
RESOURCE_PREFIX_TO_PROVINCE = {
    "jinan": "hebei",
    "jibei": "hebei",
    "mengdong": "neimenggu",
    "mengxi": "neimenggu",
    "HAB2tegaoya": "heilongjiang",
}


def parse_number(value: str | None, *, blank_as_zero: bool = False) -> float:
    text = "" if value is None else str(value).strip().replace(",", "")
    if not text:
        if blank_as_zero:
            return 0.0
        raise ValueError("A required numeric value is blank")
    number = float(text)
    if not math.isfinite(number):
        raise ValueError(f"Non-finite numeric value: {value!r}")
    return number


def identify_technology(resource: str) -> str:
    name = resource.lower()
    if "_small_" in name:
        return "small"
    if "_naturalgas_" in name:
        return "naturalgas"
    if "_subcritical_" in name:
        return "subcritical"
    # Check ultra before super because "ultrasupercritical" contains
    # "supercritical".
    if "_ultrasupercritical_" in name:
        return "ultrasupercritical"
    if "_supercritical_" in name:
        return "supercritical"
    raise ValueError(f"Cannot classify thermal resource: {resource}")


def identify_province(resource: str) -> str:
    prefix = resource.split("_", 1)[0]
    return RESOURCE_PREFIX_TO_PROVINCE.get(prefix, prefix)


def read_statistics(path: Path, unit_scale: float) -> dict[str, float]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"Statistics file has no header: {path}")
        required = {"地区", "供热容量（万千瓦）"}
        missing = required.difference(reader.fieldnames)
        if missing:
            raise ValueError(
                f"Statistics file is missing columns {sorted(missing)}; "
                f"found {reader.fieldnames}"
            )

        targets: dict[str, float] = {}
        for row in reader:
            province_name = (row.get("地区") or "").strip()
            if not province_name:
                continue
            if province_name not in STAT_PROVINCE_TO_KEY:
                raise ValueError(f"Unknown province in statistics: {province_name}")
            key = STAT_PROVINCE_TO_KEY[province_name]
            if key in targets:
                raise ValueError(f"Duplicate province in statistics: {province_name}")
            value = parse_number(row.get("供热容量（万千瓦）"), blank_as_zero=True)
            if value < 0:
                raise ValueError(f"Negative heat capacity for {province_name}: {value}")
            targets[key] = value * unit_scale
    return targets


def read_thermal(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"Thermal file has no header: {path}")
        required = {"Resource", "Zone", "Existing_Cap_MW", "Minimum_Commitment"}
        missing = required.difference(reader.fieldnames)
        if missing:
            raise ValueError(
                f"Thermal file is missing columns {sorted(missing)}; "
                f"found {reader.fieldnames}"
            )
        return list(reader.fieldnames), list(reader)


def allocate_coefficients(capacity: dict[str, float], target: float) -> dict[str, float]:
    """Allocate one coefficient per technology using the required priority."""
    if target <= 0:
        return {technology: 0.0 for technology in TECHNOLOGY_PRIORITY}

    total_available = sum(capacity[technology] for technology in TECHNOLOGY_PRIORITY)
    if target >= total_available:
        # This also implements the explicit Shanxi rule: all technologies are 1
        # when the statistical target exceeds available model capacity.
        return {technology: 1.0 for technology in TECHNOLOGY_PRIORITY}

    coefficients: dict[str, float] = {}
    remaining = target
    for technology in TECHNOLOGY_PRIORITY:
        class_capacity = capacity[technology]
        if remaining <= 0:
            coefficient = 0.0
        elif class_capacity <= 0:
            # Preserve the stated ordering: a zero-capacity class before the
            # boundary is considered fully included, although it adds no MW.
            coefficient = 1.0
        elif remaining >= class_capacity:
            coefficient = 1.0
            remaining -= class_capacity
        else:
            coefficient = remaining / class_capacity
            remaining = 0.0
        coefficients[technology] = coefficient
    return coefficients


def format_coefficient(value: float) -> str:
    if abs(value) < 1e-12:
        return "0"
    if abs(value - 1.0) < 1e-12:
        return "1"
    return f"{value:.12f}".rstrip("0").rstrip(".")


def calibrate(
    thermal_path: Path,
    statistics_path: Path,
    output_path: Path,
    summary_path: Path,
    unit_scale: float,
) -> None:
    targets = read_statistics(statistics_path, unit_scale)
    fieldnames, rows = read_thermal(thermal_path)

    capacity: dict[str, dict[str, float]] = defaultdict(
        lambda: {technology: 0.0 for technology in TECHNOLOGY_PRIORITY}
    )
    old_policy_capacity: dict[str, float] = defaultdict(float)
    row_metadata: list[tuple[str | None, str, float]] = []
    excluded_zone_rows = 0
    excluded_zone_capacity = 0.0

    for row in rows:
        resource = row["Resource"]
        technology = identify_technology(resource)
        existing_capacity = parse_number(row["Existing_Cap_MW"])
        if existing_capacity < 0:
            raise ValueError(f"Negative Existing_Cap_MW for {resource}")
        zone = int(parse_number(row["Zone"]))
        if zone > 33:
            excluded_zone_rows += 1
            excluded_zone_capacity += existing_capacity
            row_metadata.append((None, technology, existing_capacity))
            continue

        province = identify_province(resource)
        old_coefficient = parse_number(row["Minimum_Commitment"], blank_as_zero=True)
        capacity[province][technology] += existing_capacity
        old_policy_capacity[province] += existing_capacity * old_coefficient
        row_metadata.append((province, technology, existing_capacity))

    missing_statistics = sorted(set(capacity).difference(targets))
    if missing_statistics:
        raise ValueError(
            "Model provinces missing from statistics: " + ", ".join(missing_statistics)
        )

    coefficients = {
        province: allocate_coefficients(capacity[province], target)
        for province, target in targets.items()
    }

    for row, (province, technology, _) in zip(rows, row_metadata):
        if province is None:
            row["Minimum_Commitment"] = "0"
        else:
            row["Minimum_Commitment"] = format_coefficient(
                coefficients[province][technology]
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    summary_fields = [
        "地区",
        "统计目标_MW",
        "原政策容量_MW",
        *[f"{technology}_容量_MW" for technology in TECHNOLOGY_PRIORITY],
        *[f"{technology}_Minimum_Commitment" for technology in TECHNOLOGY_PRIORITY],
        "校准后政策容量_MW",
        "与统计目标差额_MW",
        "状态",
    ]
    with summary_path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=summary_fields)
        writer.writeheader()
        for province_name, province in STAT_PROVINCE_TO_KEY.items():
            target = targets.get(province, 0.0)
            province_capacity = capacity[province]
            province_coefficients = coefficients[province]
            calibrated = sum(
                province_capacity[technology] * province_coefficients[technology]
                for technology in TECHNOLOGY_PRIORITY
            )
            gap = target - calibrated
            status = "容量不足_全部设为1" if gap > 1e-6 else "已匹配"
            summary_row: dict[str, str | float] = {
                "地区": province_name,
                "统计目标_MW": target,
                "原政策容量_MW": old_policy_capacity[province],
                "校准后政策容量_MW": calibrated,
                "与统计目标差额_MW": gap,
                "状态": status,
            }
            for technology in TECHNOLOGY_PRIORITY:
                summary_row[f"{technology}_容量_MW"] = province_capacity[technology]
                summary_row[f"{technology}_Minimum_Commitment"] = format_coefficient(
                    province_coefficients[technology]
                )
            writer.writerow(summary_row)

    # Final integrity checks.
    for province, target in targets.items():
        calibrated = sum(
            capacity[province][technology] * coefficients[province][technology]
            for technology in TECHNOLOGY_PRIORITY
        )
        available = sum(capacity[province].values())
        expected = min(target, available)
        if not math.isclose(calibrated, expected, rel_tol=0.0, abs_tol=1e-6):
            raise AssertionError(
                f"Calibration failed for {province}: {calibrated} != {expected}"
            )

    print(f"Updated Thermal CSV: {output_path}")
    print(f"Calibration summary: {summary_path}")
    print(
        f"Excluded Zone > 33: {excluded_zone_rows} rows, "
        f"{excluded_zone_capacity:g} MW, all Minimum_Commitment = 0"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thermal", required=True, type=Path, help="Input Thermal.csv")
    parser.add_argument(
        "--statistics", required=True, type=Path, help="Provincial heat-capacity CSV"
    )
    parser.add_argument("--output", required=True, type=Path, help="Output Thermal.csv")
    parser.add_argument(
        "--summary", required=True, type=Path, help="Output calibration summary CSV"
    )
    parser.add_argument(
        "--unit-scale",
        type=float,
        default=10.0,
        help="Multiplier from statistics units to MW (default: 10 for 万千瓦)",
    )
    args = parser.parse_args()
    calibrate(
        args.thermal,
        args.statistics,
        args.output,
        args.summary,
        args.unit_scale,
    )


if __name__ == "__main__":
    main()
