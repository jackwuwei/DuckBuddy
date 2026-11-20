//! BLE 广播解析：平台层把原始广播字段交进来，核心决定这是不是一只鸭子、地址是什么。
//!
//! 地址解码直接用官方 `duck_ble::adv`（"另写一份解码器只会和自己一致"）。

use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Advertisement {
    /// 广播名，如 `duck-1a2b`。
    pub name: String,
    /// 已联网时的 IPv4；`None` 表示未联网或旧固件。
    pub ipv4: Option<String>,
    /// 广播里带地址字段（即使是 0.0.0.0）——区分"旧固件"和"没联网"。
    pub has_address_field: bool,
    /// 扩展广播双胞胎（与传统广播是同一只机器人）。
    pub is_extended: bool,
    /// 忙碌广播：鸭子正被另一台设备通过蓝牙连接。btd 一次只服务一个连接，期间改发不可连接的
    /// 广播（内容相同），所以它能被看到但不能作为连接目标。
    pub busy: bool,
}

/// 官方服务 UUID（扫描时用来识别鸭子）。
#[uniffi::export]
pub fn service_uuid() -> String {
    duck_ble::gatt::SERVICE_UUID.to_string()
}

/// 唯一的 RPC 特征 UUID（写请求、订阅回复、读一次取 API 版本触发配对）。
#[uniffi::export]
pub fn rpc_characteristic_uuid() -> String {
    duck_ble::gatt::RPC_UUID.to_string()
}

/// 一条通知能承载的最大字节数（不能简单用 mtu-3，见官方 framing.rs）。
#[uniffi::export]
pub fn notification_payload(mtu: u16) -> u32 {
    duck_ble::framing::notification_payload(mtu) as u32
}

/// 解析广播。不是鸭子（没有服务 UUID）时返回 `None`。不可连接的是忙碌广播，照样解析并标记
/// `busy`：它不能作为连接目标，但能告诉用户"鸭子在被别的设备连着"，而不是"找不到"
/// （authenticated-app-mvp.md "Busy broadcasts"）。
#[uniffi::export]
pub fn parse_advertisement(
    name: Option<String>,
    service_uuids: Vec<String>,
    manufacturer_data: HashMap<u16, Vec<u8>>,
    connectable: bool,
) -> Option<Advertisement> {
    let ours = duck_ble::gatt::SERVICE_UUID.to_string();
    if !service_uuids.iter().any(|u| u.eq_ignore_ascii_case(&ours)) {
        return None;
    }
    let name = name.filter(|n| !n.is_empty())?;
    Some(Advertisement {
        name,
        ipv4: duck_ble::adv::address_in(&manufacturer_data).map(|a| a.to_string()),
        has_address_field: duck_ble::adv::has_address_field(&manufacturer_data),
        is_extended: duck_ble::adv::is_extended(&manufacturer_data),
        busy: !connectable,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn decodes_address_and_filters() {
        let data = HashMap::from([(
            duck_ble::adv::COMPANY_ID,
            duck_ble::adv::extended_address_data(Some(Ipv4Addr::new(192, 168, 1, 7))),
        )]);
        let uuids = vec![service_uuid().to_uppercase()];
        let ad = parse_advertisement(Some("duck-1a2b".into()), uuids.clone(), data.clone(), true).unwrap();
        assert_eq!(ad.ipv4.as_deref(), Some("192.168.1.7"));
        assert!(ad.is_extended);
        assert!(!ad.busy);
        let busy = parse_advertisement(Some("duck-1a2b".into()), uuids, data.clone(), false).unwrap();
        assert!(busy.busy);
        assert_eq!(busy.ipv4.as_deref(), Some("192.168.1.7"));
        assert!(parse_advertisement(Some("duck-1a2b".into()), vec![], data, true).is_none());
    }
}
