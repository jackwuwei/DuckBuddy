# duck-fanstat（可选）

把机器人上 `fanctl` 的风扇状态以只读方式提供给 DuckBuddy 状态页。官方 `robot.health` 不含风扇，所以这是一个可选的加装服务。

**不装也完全正常**：App 读不到它时，状态页只是不显示风扇那一格（保持一行三格），其他功能不受影响。只有加装了风扇、并且装了 `fanctl` 的机器人才需要它。

- 接口：`GET http://<机器人 IP>:8096/fan`，返回 `duckbuddy.fan/v1` JSON（`temp_c`、`fans[].pct/rpm/mode/health`）。
- 只向 fanctl 的 root socket 发送 `{"op":"status"}`，局域网里改不了风速。
- fanctl 每次测速会忙轮询约 0.4 s，所以结果缓存 3 s，并且只在有人请求时才去问。

安装（在机器人上，本目录下）：

```sh
sudo sh install.sh
```

卸载：

```sh
sudo systemctl disable --now duck-fanstat.service
sudo rm /etc/systemd/system/duck-fanstat.service /usr/local/bin/duck-fanstat
```
