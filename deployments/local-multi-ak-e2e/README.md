# 本地多 AK/SK 端到端环境

在本目录使用当前仓库的 `Dockerfile` 构建 lakeFS（OSS），并连接 PostgreSQL。

## 前置

- Docker 与 Docker Compose v2
- 本机已安装 **`lakectl`**（与当前 lakeFS API 版本匹配为佳）
- `curl`、`jq`、`perl`（脚本仅首次 setup 用 curl+jq；其余用 lakectl；perl 用于解析无 JSON 的 create 输出）

## 启动

```bash
cd deployments/local-multi-ak-e2e
docker compose up -d --build
```

首次构建会包含 **前端 `npm run build`**（镜像内完成），比纯 Go 镜像更久，属正常情况。lakeFS 监听 `http://127.0.0.1:8000`（若 **8000** 被占用，可设置 `LAKEFS_HOST_PORT`，例如 `LAKEFS_HOST_PORT=18000 docker compose up -d`，并把下面 `LAKEFS_BASE_URL` 改成对应端口）。

PostgreSQL **默认不暴露到宿主机**，只供容器网络内的 lakeFS 使用，因此与本机是否占用 5433 等端口无关。若需要从本机连库调试，可执行：`docker compose exec postgres psql -U lakefs -d postgres`。

## 跑端到端脚本

```bash
export LAKEFS_BASE_URL=http://127.0.0.1:8000   # 若改了端口请同步修改
# 可选：使用刚编译的 lakectl
# export LAKECTL="$(pwd)/../../lakectl"
./e2e-multi-ak.sh
```

脚本会：curl 完成首次 `setup`；随后用 **lakectl** 做 `auth users credentials` 的 list/create/delete，以及 `repo create` / `repo list` / `branch list`；最后验证吊销的 AK 无法再访问。

## 清理

```bash
docker compose down -v
```

`-v` 删除卷，便于下次重新 setup。
