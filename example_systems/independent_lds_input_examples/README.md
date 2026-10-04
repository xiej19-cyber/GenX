# Independent long-duration storage input example

This directory contains the input fragments needed to add an independent LDES candidate
beside ordinary 2-hour and 4-hour batteries. Copy the rows into the corresponding files
of a complete GenX case; the numerical costs and accreditation factors are illustrative.

For the included four-week metadata, input profiles must contain 672 rows in the order
spring, summer, autumn, winter. `TimeDomainReduction` remains `0`. GenX constructs the
LDS calendar mapping internally, so no `Period_map.csv` is needed. Twelve monthly weeks
are also supported when supplied in January-to-December order with 2,016 profile rows.
The LDS chronology links 52 complete weeks; the final 24 hours remain represented in
annual weights and reconstructed output, following GenX's standard weekly convention.

`CRM_peakload` and `CapacityPayment` may be enabled independently or together. If both
are enabled, check the economic interpretation carefully because a resource can receive
both CRM shadow-price revenue and an exogenous capacity payment.
