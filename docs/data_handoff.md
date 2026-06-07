# 数据部分交接说明

这份文档用于交接数据负责人已经完成的工作，并说明模型负责人、结果分析与可视化负责人如何继续使用。

## 我已经提供了什么

### 已上传到 GitHub 的内容

这些内容应该上传，便于队友复现和检查：

| 路径 | 作用 |
| --- | --- |
| `src/data/download_orders.py` | 按页调用深圳开放平台接口，下载订单原始 JSONL |
| `src/data/download_peak_sample.py` | 下载 10 个早晚高峰代表页样本 |
| `src/data/build_rebalancing_inputs.py` | 从原始 JSONL 生成清洗数据、网格需求表、OD 流和距离矩阵 |
| `src/data/validate_rebalancing_inputs.py` | 校验最终数据产物是否满足交付要求 |
| `src/bike_rebalancing/data_pipeline.py` | 数据清洗、网格划分、场景聚合、OD 和距离矩阵的核心代码 |
| `docs/data_source.md` | 数据来源、接口参数、字段映射和清洗规则 |
| `docs/data_deliverables.md` | 当前数据规模、输出文件说明、质量摘要 |
| `docs/data_handoff.md` | 本交接文档 |
| `tests/test_data_pipeline.py` | 数据处理逻辑测试 |
| `requirements.txt` | 运行数据部分所需 Python 依赖 |

### 留在本地的内容

这些内容不应上传到公开 GitHub：

| 路径或文件 | 原因 |
| --- | --- |
| `data/raw/` | 原始订单数据较大，不适合提交 Git |
| `data/processed/` | 处理后数据文件包含大量派生数据，应本地保存或私下共享 |
| `接口信息.png`、`接口测试.png` | 截图中包含 `appKey`，不能公开上传 |
| `.pytest_cache/`、`__pycache__/` | 本地运行缓存，没有协作价值 |

`.gitignore` 已经忽略上述本地数据和敏感截图。

## 当前本地数据结果

当前本地已经生成了一版可用的数据交付物：

| 指标 | 数量 |
| --- | ---: |
| 原始订单样本 | 291,000 |
| 清洗后福田相关订单 | 69,357 |
| 早晚高峰场景 | 10 |
| 1km 网格需求表行数 | 1,150 |
| 1km OD 流行数 | 8,660 |

场景覆盖范围：

- 日期：`2021-05-10` 至 `2021-05-14`
- 区域：福田区近似边界框
- 高峰：早高峰 `07:00-10:00`，晚高峰 `17:00-20:00`
- 网格：主模型使用 `1km`，敏感性分析保留 `500m`

## 给模型负责人的使用方式

模型负责人优先使用下面两个文件：

```text
data/processed/scenario_grid_demand_1km.parquet
data/processed/distance_matrix_1km.parquet
```

`scenario_grid_demand_1km.parquet` 中的关键字段：

| 字段 | 含义 |
| --- | --- |
| `scenario_id` | 场景编号，例如 `20210510_am_peak` |
| `grid_id` | 网格编号 |
| `departures` | 该场景该网格出发订单数 |
| `arrivals` | 该场景该网格到达订单数 |
| `net_outflow` | `departures - arrivals` |
| `shortage` | `max(net_outflow, 0)`，短缺量 |
| `surplus` | `max(-net_outflow, 0)`，富余量 |

建模建议：

- 富余区域集合：`surplus > 0`
- 短缺区域集合：`shortage > 0`
- 调度成本：从 `distance_matrix_1km.parquet` 读取 `distance_km`
- 每个 `scenario_id` 可以独立求解一次，用于多场景鲁棒分析
- 服务公平性可以基于每个短缺网格的满足率计算

## 给结果分析与可视化负责人的使用方式

可视化负责人优先使用下面几个文件：

```text
data/processed/orders_clean_futian_week.parquet
data/processed/od_flow_grid_1km.parquet
data/processed/grid_metadata_1km.csv
data/processed/grid_metadata_500m.csv
data/processed/scenario_grid_demand_1km.parquet
```

推荐图表：

- 每个场景的短缺/富余网格分布图
- `net_outflow` 热力图
- 主要 OD 流向图
- 早晚高峰订单量对比图
- 1km 与 500m 网格尺度对比图

## 如何复现数据

1. 安装依赖：

```powershell
pip install -r requirements.txt
```

2. 设置深圳开放平台 `appKey`：

```powershell
$env:SHENZHEN_OPEN_DATA_APP_KEY="你的appKey"
```

3. 下载高峰代表页样本：

```powershell
python src/data/download_peak_sample.py --pages-per-window 2
```

4. 生成模型输入表：

```powershell
python src/data/build_rebalancing_inputs.py data/raw/*.jsonl
```

5. 校验数据产物：

```powershell
python src/data/validate_rebalancing_inputs.py
```

成功时应看到：

```text
validated=true
scenario_count=10
grid_rows_1km=1150
od_flow_rows_1km=8660
```

## 交接注意事项

- GitHub 上只保存复现流程、代码、测试和说明文档。
- 本地数据文件可以通过网盘、U 盘或课堂提交系统单独共享。
- 不要把 `appKey`、接口截图、原始订单数据提交到公开仓库。
- 如果后续需要全量数据，可以把 `download_orders.py` 的 `--max-pages` 提高到目标周总页数约 `787` 页，再重新运行构建脚本。
