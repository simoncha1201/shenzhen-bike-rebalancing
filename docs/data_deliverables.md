# 数据部分交付说明

## 当前交付定位

本数据部分用于支持“福田区一周早晚高峰共享单车再平衡”建模与可视化分析。

当前本地数据采用高峰代表页抽样，而不是整周 786 万条全量下载。抽样页码根据接口返回的时间排序定位到每个工作日早晚高峰附近，保证 5 个工作日 × 早晚高峰共 10 个场景都有数据。

## 已生成的数据规模

| 指标 | 数量 |
| --- | ---: |
| 原始订单样本 | 291,000 |
| 清洗后福田相关订单 | 69,357 |
| 1km 网格需求表行数 | 1,150 |
| 1km OD 流行数 | 8,660 |
| 高峰场景数 | 10 |

## 场景订单量

| 场景 | 日期 | 高峰 | 清洗后订单数 |
| --- | --- | --- | ---: |
| `20210510_am_peak` | 2021-05-10 | 早高峰 | 26,664 |
| `20210510_pm_peak` | 2021-05-10 | 晚高峰 | 5,630 |
| `20210511_am_peak` | 2021-05-11 | 早高峰 | 3,758 |
| `20210511_pm_peak` | 2021-05-11 | 晚高峰 | 5,323 |
| `20210512_am_peak` | 2021-05-12 | 早高峰 | 4,567 |
| `20210512_pm_peak` | 2021-05-12 | 晚高峰 | 4,034 |
| `20210513_am_peak` | 2021-05-13 | 早高峰 | 4,284 |
| `20210513_pm_peak` | 2021-05-13 | 晚高峰 | 4,226 |
| `20210514_am_peak` | 2021-05-14 | 早高峰 | 3,763 |
| `20210514_pm_peak` | 2021-05-14 | 晚高峰 | 4,123 |

## 输出文件

输出文件位于 `data/processed/`，已作为模型/可视化输入数据提交到 GitHub，队友 pull 后可以直接使用。

| 文件 | 用途 | 交给谁 |
| --- | --- | --- |
| `orders_clean_futian_week.parquet` | 清洗后的福田相关订单 | 数据/可视化 |
| `scenario_grid_demand_1km.parquet` | 主模型输入：每个场景每个 1km 网格的供需差异 | 模型 |
| `scenario_grid_demand_500m.parquet` | 网格尺度敏感性分析 | 模型/可视化 |
| `od_flow_grid_1km.parquet` | 网格 OD 流，用于流向分析和可视化 | 模型/可视化 |
| `distance_matrix_1km.parquet` | 网格中心距离矩阵，用于调度成本 | 模型 |
| `grid_metadata_1km.csv` | 1km 网格中心坐标和编号 | 模型/可视化 |
| `grid_metadata_500m.csv` | 500m 网格中心坐标和编号 | 可视化 |
| `data_quality_summary.csv` | 清洗过程各阶段删除数量 | 数据 |
| `scenario_order_counts.csv` | 每个场景订单量 | 数据/分析 |

## 清洗结果摘要

| 阶段 | 删除数量 | 剩余数量 |
| --- | ---: | ---: |
| 原始记录 | 0 | 291,000 |
| 删除缺失时间或坐标 | 0 | 291,000 |
| 删除异常骑行时长 | 4,254 | 286,746 |
| 删除深圳范围外异常坐标 | 226 | 286,520 |
| 删除起终点都不在福田边界框的订单 | 217,022 | 69,498 |
| 删除重复订单样记录 | 141 | 69,357 |

## 复现命令

设置接口密钥：

```powershell
$env:SHENZHEN_OPEN_DATA_APP_KEY="你的appKey"
```

下载 10 个高峰窗口的代表页样本：

```powershell
python src/data/download_peak_sample.py --pages-per-window 2
```

生成模型输入表：

```powershell
python src/data/build_rebalancing_inputs.py data/raw/*.jsonl
```

校验数据产物：

```powershell
python src/data/validate_rebalancing_inputs.py
```

## 给模型负责人的接口说明

主模型应优先读取 `scenario_grid_demand_1km.parquet` 和 `distance_matrix_1km.parquet`。

`scenario_grid_demand_1km.parquet` 的核心字段：

- `scenario_id`：场景编号，例如 `20210510_am_peak`
- `grid_id`：网格编号
- `departures`：该场景该网格出发订单数
- `arrivals`：该场景该网格到达订单数
- `net_outflow`：`departures - arrivals`
- `shortage`：`max(net_outflow, 0)`，短缺量
- `surplus`：`max(-net_outflow, 0)`，富余量

模型中的富余集合可取 `surplus > 0` 的网格，短缺集合可取 `shortage > 0` 的网格，调度成本可从 `distance_matrix_1km.parquet` 读取。

## 注意事项

- 当前数据适合课程项目建模和展示，但不是完整 5 天全量高峰订单。
- 若时间和磁盘允许，可把 `download_orders.py --max-pages 787 --rows 10000` 用于下载目标周全量数据，再重新运行构建脚本。
- 原始数据、处理后数据和接口截图不应提交到公开 GitHub。
