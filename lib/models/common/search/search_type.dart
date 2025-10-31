
// ignore_for_file: constant_identifier_names
enum SearchType {
  // 视频：video
  video('视频'),
  // 综合：all（混合类型列表）
  all('综合'),
  // 番剧：media_bangumi
  media_bangumi('番剧'),
  // 影视：media_ft
  media_ft('影视'),
  // 直播间：live_room
  live_room('直播间'),
  // 用户：bili_user
  bili_user('用户'),
  // 专栏：article
  article('专栏');

  final String label;
  const SearchType(this.label);
}