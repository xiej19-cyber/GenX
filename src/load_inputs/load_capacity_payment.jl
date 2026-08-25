@doc raw"""
    load_capacity_payment!(setup::Dict, case_path::AbstractString, inputs::Dict)

Load regional prices from `Capacity_payment.csv` and resource-specific accredited-capacity
factors from `resources/policy_assignments/Resource_capacity_payment.csv`.

Prices are in \$/accredited-MW-year. The assignment file uses the same layout as a CRM
assignment file: `Resource,Derating_Factor_1,...,Derating_Factor_N`.
"""
function load_capacity_payment!(setup::Dict, case_path::AbstractString, inputs::Dict)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1.0
    policies_path = joinpath(case_path, setup["PoliciesFolder"])

    price_filename = "Capacity_payment.csv"
    price_path = joinpath(policies_path, price_filename)
    isfile(price_path) || error(
        "CapacityPayment=1 requires $(price_filename) in $(policies_path).")
    price_df = load_dataframe(price_path)
    rename!(price_df, lowercase.(names(price_df)))
    all(col -> col in names(price_df), ["cappayment_region", "capacityprice"]) ||
        error("$(price_filename) must contain CapPayment_Region and CapacityPrice columns.")
    nrow(price_df) > 0 || error("$(price_filename) must contain at least one region.")

    expected_regions = ["CapPayment_$r" for r in 1:nrow(price_df)]
    String.(price_df.cappayment_region) == expected_regions || error(
        "$(price_filename) regions must be ordered and named " *
        join(expected_regions, ", ") * ".")
    prices = price_df.capacityprice
    all(p -> !ismissing(p) && p isa Real && isfinite(p) && p >= 0, prices) ||
        error("CapacityPrice values in $(price_filename) must be finite and nonnegative.")

    assignment_filename = "Resource_capacity_payment.csv"
    assignment_path = joinpath(case_path, setup["ResourcesFolder"],
        setup["ResourcePoliciesFolder"], assignment_filename)
    isfile(assignment_path) || error(
        "CapacityPayment=1 requires $(assignment_filename) in $(dirname(assignment_path)).")
    assignment_df = load_dataframe(assignment_path)
    rename!(assignment_df, lowercase.(names(assignment_df)))
    "resource" in names(assignment_df) ||
        error("$(assignment_filename) must contain a Resource column.")

    N = nrow(price_df)
    expected_factor_cols = ["derating_factor_$r" for r in 1:N]
    actual_factor_cols = filter(c -> startswith(c, "derating_factor_"), names(assignment_df))
    actual_factor_cols == expected_factor_cols || error(
        "$(assignment_filename) must contain exactly " *
        join(["Derating_Factor_$r" for r in 1:N], ", ") * ".")
    length(unique(String.(assignment_df.resource))) == nrow(assignment_df) ||
        error("$(assignment_filename) contains duplicate Resource names.")

    gen = inputs["RESOURCES"]
    resource_index = Dict(resource_name(gen[g]) => g for g in eachindex(gen))
    factors = zeros(Float64, length(gen), N)
    for row in eachrow(assignment_df)
        name = String(row.resource)
        haskey(resource_index, name) || error(
            "Resource $(name) in $(assignment_filename) was not found in the resource inputs.")
        values = [row[Symbol(col)] for col in expected_factor_cols]
        all(v -> !ismissing(v) && v isa Real && isfinite(v) && 0 <= v <= 1, values) ||
            error("Derating factors for resource $(name) must be finite values between 0 and 1.")
        factors[resource_index[name], :] .= Float64.(values)
    end

    inputs["NCapacityPaymentRegions"] = N
    inputs["capacity_payment_price"] = Float64.(prices) ./ scale_factor
    inputs["CAPACITY_PAYMENT_DERATING_FACTOR"] = factors
    println("Capacity payment prices and resource assignments Successfully Read!")
    return nothing
end
