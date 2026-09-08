/// 火山引擎（Volcengine）语音合成可用的音色目录。
///
/// 数据源：仓库根目录 `voice.md`（每两行一对：speaker_id / 中文名）。
/// 该表既用于角色表单里的音色下拉框，也用于语音服务配置页的“默认音色”。
/// 若在别处需要新增音色，请同步修改 `voice.md` 与本表的 `presets`，
/// 并运行 `test/voice_catalog_test.dart` 校验两者一致。
library;

/// 一个可选的 TTS 音色：`id` 即火山大模型语音合成接口的 `speaker` 取值。
class VoicePreset {
  const VoicePreset(this.id, this.name);

  /// 火山接口的 speaker id，例如 `zh_female_meilinvyou_moon_bigtts`。
  final String id;

  /// 给人看的中文名，例如 `魅力女友`。
  final String name;

  @override
  String toString() => '$name($id)';
}

/// 全部可选音色（与 `voice.md` 保持一致，顺序即文件顺序）。
const List<VoicePreset> voicePresets = <VoicePreset>[
  VoicePreset('zh_female_wanqudashu_moon_bigtts', '湾区大叔'),
  VoicePreset('zh_female_daimengchuanmei_moon_bigtts', '呆萌川妹'),
  VoicePreset('zh_male_guozhoudege_moon_bigtts', '广州德哥'),
  VoicePreset('zh_male_beijingxiaoye_moon_bigtts', '北京小爷'),
  VoicePreset('zh_male_shaonianzixin_moon_bigtts', '少年梓辛/Brayan'),
  VoicePreset('zh_female_meilinvyou_moon_bigtts', '魅力女友'),
  VoicePreset('zh_male_shenyeboke_moon_bigtts', '深夜播客'),
  VoicePreset('zh_female_sajiaonvyou_moon_bigtts', '柔美女友'),
  VoicePreset('zh_female_yuanqinvyou_moon_bigtts', '撒娇学妹'),
  VoicePreset('zh_male_haoyuxiaoge_moon_bigtts', '浩宇小哥'),
  VoicePreset('zh_male_guangxiyuanzhou_moon_bigtts', '广西远舟'),
  VoicePreset('zh_female_meituojieer_moon_bigtts', '妹坨洁儿'),
  VoicePreset('zh_male_yuzhouzixuan_moon_bigtts', '豫州子轩'),
  VoicePreset('zh_female_linjianvhai_moon_bigtts', '邻家女孩'),
  VoicePreset('zh_female_gaolengyujie_moon_bigtts', '高冷御姐'),
  VoicePreset('zh_male_yuanboxiaoshu_moon_bigtts', '渊博小叔'),
  VoicePreset('zh_male_yangguangqingnian_moon_bigtts', '阳光青年'),
  VoicePreset('zh_male_aojiaobazong_moon_bigtts', '傲娇霸总'),
  VoicePreset('zh_male_jingqiangkanye_moon_bigtts', '京腔侃爷/Harmony'),
  VoicePreset('zh_female_shuangkuaisisi_moon_bigtts', '爽快思思/Skye'),
  VoicePreset('zh_male_wennuanahu_moon_bigtts', '温暖阿虎/Alvin'),
  VoicePreset('zh_female_wanwanxiaohe_moon_bigtts', '湾湾小何'),
  VoicePreset('ICL_zh_female_bingruoshaonv_tob', '病弱少女'),
  VoicePreset('ICL_zh_female_huoponvhai_tob', '活泼女孩'),
  VoicePreset('ICL_zh_female_heainainai_tob', '和蔼奶奶'),
  VoicePreset('ICL_zh_female_linjuayi_tob', '邻居阿姨'),
  VoicePreset('zh_female_wenrouxiaoya_moon_bigtts', '温柔小雅'),
  VoicePreset('zh_female_tianmeixiaoyuan_moon_bigtts', '甜美小源'),
  VoicePreset('zh_female_qingchezizi_moon_bigtts', '清澈梓梓'),
  VoicePreset('zh_male_dongfanghaoran_moon_bigtts', '东方浩然'),
  VoicePreset('zh_male_jieshuoxiaoming_moon_bigtts', '解说小明'),
  VoicePreset('zh_female_kailangjiejie_moon_bigtts', '开朗姐姐'),
  VoicePreset('zh_male_linjiananhai_moon_bigtts', '邻家男孩'),
  VoicePreset('zh_female_tianmeiyueyue_moon_bigtts', '甜美悦悦'),
  VoicePreset('zh_female_xinlingjitang_moon_bigtts', '心灵鸡汤'),
  VoicePreset('zh_female_cancan_mars_bigtts', '灿灿'),
  VoicePreset('en_female_anna_mars_bigtts', 'Anna'),
  VoicePreset('zh_male_tiancaitongsheng_mars_bigtts', '天才童声'),
  VoicePreset('zh_male_naiqimengwa_mars_bigtts', '奶气萌娃'),
  VoicePreset('zh_female_zhixingnvsheng_mars_bigtts', '知性女声'),
  VoicePreset('zh_female_qingxinnvsheng_mars_bigtts', '清新女声'),
  VoicePreset('zh_male_jieshuonansheng_mars_bigtts', '磁性解说男声'),
  VoicePreset('zh_male_chunhui_mars_bigtts', '广告解说'),
  VoicePreset('zh_male_qingshuangnanda_mars_bigtts', '清爽男大'),
];

/// 由音色 id 反查 [VoicePreset]；找不到返回 null。
VoicePreset? voicePresetById(String id) {
  for (final v in voicePresets) {
    if (v.id == id) return v;
  }
  return null;
}
