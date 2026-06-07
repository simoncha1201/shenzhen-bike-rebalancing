# 数据来源与获取说明

## 数据集

- 数据来源：深圳市政府数据开放平台
- 数据接口：共享单车企业每日订单表
- 接口地址：`https://opendata.sz.gov.cn/api/29200_00403627/1/service.xhtml`
- 支持格式：JSON
- 研究范围：福田区近似边界框，`lng 113.98-114.13`，`lat 22.49-22.58`
- 目标日期：`2021-05-10` 至 `2021-05-14`
- 高峰时段：早高峰 `07:00-10:00`，晚高峰 `17:00-20:00`

使用项目成果时，应注明数据来源为“深圳市政府数据开放平台”。

## 接口参数

平台接口需要申请应用并获取 `appKey`。不要把 `appKey` 写入仓库，建议使用环境变量：

```powershell
$env:SHENZHEN_OPEN_DATA_APP_KEY="你的appKey"
```

主要参数：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `appKey` | 是 | 平台个人中心或应用中获取的接口密钥 |
| `page` | 是 | 当前页码，从 1 开始 |
| `rows` | 是 | 每页条数，平台限制每页不超过 10000 |
| `startDate` | 否 | 入库日期开始，格式 `yyyymmdd` |
| `endDate` | 否 | 入库日期结束，格式 `yyyymmdd` |

## 已核验的接口行为

按截图中的接口信息测试，POST 请求可以正常返回数据：

```text
page=1&rows=10&startDate=20210510&endDate=20210514
```

目标周返回的 `total` 约为 786 万条记录，因此完整下载前应先用 `--max-pages 1` 跑通样本流程。

接口返回字段为大写形式，数据管线会统一转换为小写字段：

| 接口字段 | 统一字段 | 用途 |
| --- | --- | --- |
| `USER_ID` | `user_id` | 去重和异常检查 |
| `COM_ID` | `company_id` | 企业标识 |
| `START_TIME` | `start_time` | 高峰筛选、出发量统计 |
| `START_LNG` | `start_lng` | 起点网格 |
| `START_LAT` | `start_lat` | 起点网格 |
| `END_TIME` | `end_time` | 骑行时长检查 |
| `END_LNG` | `end_lng` | 终点网格 |
| `END_LAT` | `end_lat` | 终点网格 |

## 运行方式

先下载一页样本：

```powershell
python src/data/download_orders.py --max-pages 1
```

确认样本没问题后，可以下载 10 个高峰窗口的代表页样本：

```powershell
python src/data/download_peak_sample.py --pages-per-window 2
```

如需整周全量，再提高页数。目标周全量约 787 页：

```powershell
python src/data/download_orders.py --max-pages 787
```

生成模型输入表：

```powershell
python src/data/build_rebalancing_inputs.py data/raw/bike_orders_20210510_20210514_p1.jsonl
```

输出文件默认保存在 `data/processed/`，包括：

- `orders_clean_futian_week.parquet`
- `scenario_grid_demand_1km.parquet`
- `scenario_grid_demand_500m.parquet`
- `od_flow_grid_1km.parquet`
- `distance_matrix_1km.parquet`
- `data_quality_summary.csv`
- `scenario_order_counts.csv`

## 清洗规则

- 删除缺失时间或经纬度的记录。
- 删除骑行时长小于 1 分钟或大于 120 分钟的记录。
- 删除明显不在深圳范围内的异常坐标。
- 仅保留起点或终点至少一个落入福田区近似边界框的订单。
- 删除重复订单样记录。
