CREATE PROJECTION bitmap_dbd.user_profile_DBD_1_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 snapshot_id ENCODING RLE, 
 entity_id ENCODING DELTARANGE_COMP, 
 country ENCODING RLE, 
 age ENCODING RLE, 
 consent ENCODING RLE, 
 suspended ENCODING RLE
)
AS
 SELECT tenant_id, 
        snapshot_id, 
        entity_id, 
        country, 
        age, 
        consent, 
        suspended
 FROM bitmap_dbd.user_profile 
 ORDER BY tenant_id,
          country,
          snapshot_id,
          consent,
          suspended,
          age,
          entity_id
UNSEGMENTED ALL NODES;

CREATE PROJECTION bitmap_dbd.user_interest_DBD_2_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 snapshot_id ENCODING RLE, 
 entity_id ENCODING COMMONDELTA_COMP, 
 topic ENCODING RLE
)
AS
 SELECT tenant_id, 
        snapshot_id, 
        entity_id, 
        topic
 FROM bitmap_dbd.user_interest 
 ORDER BY topic,
          tenant_id,
          snapshot_id,
          entity_id
UNSEGMENTED ALL NODES;

CREATE PROJECTION bitmap_dbd.event_log_DBD_3_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 event_id ENCODING DELTARANGE_COMP, 
 user_id ENCODING DELTAVAL, 
 event_ts ENCODING RLE, 
 channel ENCODING RLE
)
AS
 SELECT tenant_id, 
        event_id, 
        user_id, 
        event_ts, 
        channel
 FROM bitmap_dbd.event_log 
 ORDER BY channel,
          tenant_id,
          event_ts,
          event_id
UNSEGMENTED ALL NODES;

CREATE PROJECTION bitmap_dbd.device_state_DBD_4_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 snapshot_id ENCODING RLE, 
 device_id ENCODING DELTAVAL, 
 online ENCODING RLE, 
 zone ENCODING RLE, 
 temp_tenths ENCODING RLE, 
 changes_10m ENCODING RLE, 
 observed_at ENCODING GCDDELTA
)
AS
 SELECT tenant_id, 
        snapshot_id, 
        device_id, 
        online, 
        zone, 
        temp_tenths, 
        changes_10m, 
        observed_at
 FROM bitmap_dbd.device_state 
 ORDER BY tenant_id,
          zone,
          changes_10m,
          snapshot_id,
          online,
          temp_tenths,
          device_id
UNSEGMENTED ALL NODES;

CREATE PROJECTION bitmap_dbd.asset_state_DBD_5_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 snapshot_id ENCODING RLE, 
 asset_id ENCODING COMMONDELTA_COMP, 
 contains_pii ENCODING RLE, 
 deleted ENCODING RLE, 
 refreshed_at ENCODING GCDDELTA
)
AS
 SELECT tenant_id, 
        snapshot_id, 
        asset_id, 
        contains_pii, 
        deleted, 
        refreshed_at
 FROM bitmap_dbd.asset_state 
 ORDER BY tenant_id,
          snapshot_id,
          contains_pii,
          deleted,
          asset_id
UNSEGMENTED ALL NODES;

CREATE PROJECTION bitmap_dbd.asset_source_DBD_6_rep_vbitmap_dbd /*+createtype(D)*/
(
 tenant_id ENCODING RLE, 
 snapshot_id ENCODING RLE, 
 asset_id ENCODING COMMONDELTA_COMP, 
 source ENCODING RLE
)
AS
 SELECT tenant_id, 
        snapshot_id, 
        asset_id, 
        source
 FROM bitmap_dbd.asset_source 
 ORDER BY source,
          tenant_id,
          snapshot_id,
          asset_id
UNSEGMENTED ALL NODES;



