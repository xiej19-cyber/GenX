# 全国 CCUS 年碳捕集量上限方案

## 总体方案

复用现有 `CO2Cap` 政策模块，在 `CO2_cap.csv` 中增加可选字段 `CO_2_Capture_Max_Mtons_1`，不新增设置开关、不修改 `Thermal.csv` 结构，也不改动现有捕集量计算。

当前模型已经生成：

- `eEmissionsCaptureByPlant[y,t]`：机组逐时捕集量。
- `eEmissionsCaptureByPlantYear[y]`：包含 `omega` 时间权重的机组年度捕集量。

因此只需读取全国上限，并增加：

\[
\sum_{y\in CCS} eEmissionsCaptureByPlantYear_y
\leq CO2CaptureMax
\]

当前 case 的 `CO_2_Cap_Zone_1` 已覆盖全部 140 个区域，因此同一组区域映射可以直接代表全国范围。

## 实现改动

- 在 `src/load_inputs/load_co2_cap.jl` 中：
  - 可选读取 `CO_2_Capture_Max_Mtons_*` 列。
  - 输入单位沿用 CO₂ 质量约束，为百万吨/年。
  - 按现有规则转换为模型内部单位：`Mtons × 1e6 / scale_factor`。
  - 要求列编号连续，并与 `CO_2_Cap_Zone_*` 数量一致。
  - 如果该列不存在，则完全保持现有行为。

- 在 `src/model/policies/co2_cap.jl` 中：
  - 当捕集上限输入存在时，创建 `cCO2Capture_systemwide[cap]`。
  - 对每个约束，仅汇总对应 `CO_2_Cap_Zone_*` 所选区域内的 CCS 资源。
  - 使用已有 `eEmissionsCaptureByPlantYear`，自动包含稳态捕集、启动过程捕集和代表时段权重。
  - 若配置了捕集上限但没有任何 CCS 资源，给出明确的输入配置错误。

- 在 case 的 `policies/CO2_cap.csv` 中：
  - 增加 `CO_2_Capture_Max_Mtons_1`。
  - 全国上限值只填写一次，其余区域填 `0`；模型对所选区域的该列求和，因此不要在每一行重复全国目标。
  - 实际上限数值作为情景参数由用户填写。

- 不修改：
  - `Thermal.csv` 及其 CCUS、改造配置字段。
  - `src/model/core/co2.jl` 中现有捕集量公式。
  - `genx_settings.yml`；继续使用当前 `CO2Cap: 1`。
  - 现有输出结构。全国实际捕集量可由 `captured_emissions_plant.csv` 的 `AnnualSum` 求和得到。

## 测试与验收

- 输入加载测试：
  - 验证 `ParameterScale=0/1` 时上限均被正确转换。
  - 验证缺少新增列时旧 case 不创建捕集约束。
  - 验证列编号缺失、数量不匹配、负值或缺失值会产生明确错误。

- 约束测试：
  - 构造包含多个区域、CCS 与非 CCS 资源的小模型。
  - 验证只统计目标区域内的 CCS 年捕集量。
  - 验证非 CCS 资源不参与约束。
  - 验证优化结果不会超过给定上限，并检查约束名 `cCO2Capture_systemwide` 已注册。

- 当前中国 case 验收：
  - 使用用户设定的全国上限完成求解。
  - 汇总 `captured_emissions_plant.csv` 的 `AnnualSum`，确认不超过输入上限（允许求解器容差）。
  - 使用一个明显宽松上限确认结果与原模型一致；使用较紧上限确认约束能够生效。

## 假设与边界

- 约束方向确定为年度捕集量上限。
- 捕集上限依赖现有 `CO2Cap > 0`，不支持在关闭 CO₂ 政策时独立启用。
- “全国捕集量”包括所有 `CO2_Capture_Fraction > 0` 的资源，包含启动捕集，不考虑运输或封存过程中的额外泄漏。
- 首版不增加松弛变量、惩罚成本或捕集上限影子价格输出，以保持改动最小。
