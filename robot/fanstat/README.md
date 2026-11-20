# duck-fanstat

把板上 `fanctl` 的风扇状态以只读方式提供给 DuckBuddy 状态页。官方 `robot.health` 不含风扇，所以这是本机加装的服务。

- 接口：`GET http://<机器人 IP>:8096/fan`，返回 `duckbuddy.fan/v1` JSON（`temp_c`、`fans[].pct/rpm/mode/health`）。
- 只向 fanctl 的 root socket 发送 `{"op":"status"}`，局域网里改不了风速。
- fanctl 每次测速会忙轮询约 0.4 s，所以结果缓存 3 s，并且只在有人请求时才去问。
- 没装这个服务的鸭子，App 读不到就不显示风扇那一格（状态页保持一行三格）。

安装（在机器人上）：

```sh
sudo sh install.sh
```

已部署：Fanduck 本机 HAT D1 J8 风扇（PWM12_M1 第 21 脚，FG 第 24 脚）。
