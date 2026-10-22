# Capacity payment with deliverable external capacity

The payment objective remains annual cost minus annual capacity payment. Local
resources use final discharge/generation capacity times their payment factor.
External dedicated resources are paid only for deliverable accredited capacity.
For each payment region and external source zone, the model constrains the sum
of paid capacities by both resource accreditation and the signed actual net flow
on eligible connecting lines in that region's critical hour. Flow is a decision
variable in the current Payment solve, not a fixed no-CRM or CRM output value.

## Settings

```yaml
CapacityPayment: 1
CRM_peakload: 0
CRM_multihours: 0
CapacityPaymentDeliverability: 1
CapacityPaymentReference: multihours
```

Deliverability defaults to 1. For multi-zone systems, the reference defaults to
multihours and requires the following files already used by the CRM case:

- `policies/CRM_multihours.csv`: maps zones to CRM/payment regions, in the same
  numbered order as `CapPayment_1`, `CapPayment_2`, etc. Positive CapRes entries
  identify member zones. The reserve percentage is not imposed in Payment.
- `policies/CRM_multihours_selected.csv`: exactly one `CapRes,t` row per payment
  region. Multiple selected hours are rejected because the annual payment
  price's interpretation would otherwise be ambiguous.
- `system/Network.csv`: same `DerateCapRes_r` and `CapRes_Excl_r` convention as
  peakload/multihours. Dedicated-generation accounting requires zero line
  derating and nonzero signed participation. Lines must connect the external
  source zone directly to a member zone. All eligible connecting flows from the
  same source zone are aggregated, as in the CRM modules.

Set `CapacityPaymentReference: peakload` to use `CRM_peakload.csv` and determine
each region's hour from its maximum aggregate demand. No selected-hour file is
needed in that mode. Single-zone systems retain the local-resource payment rule
and require no CRM reference files. `CapacityPaymentDeliverability: 0` explicitly
restores the legacy uncapped nameplate-based payment behavior.

Payment still reads prices from `Capacity_payment.csv` (currency/accredited MW
per year) and factors from `Resource_capacity_payment.csv`. Loading reference
metadata does not enable CRM quantity constraints or CRM slack penalties and
does not overwrite the CRM inputs namespace.

## Accounting

External accredited capacity includes committed thermal maintenance/fusion
adjustments at the critical hour. Within a source-zone group, the LP determines
the aggregate paid capacity. Reports allocate it proportionally to each
resource's raw accredited capacity; all resources in that group receive the
same regional price. Thus no nonlinear capacity ratios are needed in the model.
The payment, net-revenue and zonal-cost reports use the same proportional
allocation, preserving total revenue and objective reconciliation.

`capacity_payment_per_unit.csv` now reports delivered paid MW in
`AccreditedCapacityMW`, rather than uncapped raw external MW.
`capacity_payment_delivery.csv` reports source-zone raw/paid MW, critical hour,
signed net export, delivery fraction and annual payment. The total annual
payment does not multiply the selected hour's representative weight.

As with peakload/multihours, the nonnegative credit bounded by signed flow
requires net export to be nonnegative for participating dedicated groups. An
external group with no eligible connecting line receives zero paid credit and
emits a warning. A zero payment price can leave the LP credit allocation
indeterminate; this has no monetary effect. External co-located VRE_STOR is
explicitly rejected in this accounting mode, matching the scope of the dedicated
generation mechanism; local co-located resources keep their fixed-factor rule.

This change aligns dedicated-generation delivery accounting. It does not add
payments to transmission lines, alter local resource accreditation rules, or
guarantee identical CRM/Payment outcomes if other model constraints differ.
