
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/search_panel/controller.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/id_utils.dart';

class SearchAllController
    extends SearchPanelController<SearchAllData, dynamic> {
  SearchAllController({
    required super.keyword,
    required super.searchType,
    required super.tag,
  });

  late bool hasJump2Video = false;

  @override
  void onInit() {
    super.onInit();
    jump2Video();
  }

  @override
  List? getDataList(response) {
    return response.list;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success response) {
    searchResultController?.count[searchType.index] =
        response.response.numResults ?? 0;
    if (searchType == SearchType.video && !hasJump2Video && isRefresh) {
      hasJump2Video = true;
      onPushDetail(response.response.list);
    }
    return false;
  }

  // —— 综合页也应用“精准/排除词”本地过滤 —— //
  List<String> _includes = [];
  List<String> _excludes = [];

  void _parseTerms(String text) {
    final tokens =
        text.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
    _includes = [];
    _excludes = [];
    for (final t in tokens) {
      if (t.startsWith('-') && t.length > 1) {
        _excludes.add(t.substring(1));
      } else {
        _includes.add(t);
      }
    }
  }

  String _collectText(dynamic item) {
    final buf = StringBuffer();
    void add(dynamic v) {
      if (v == null) return;
      final s = v.toString().trim();
      if (s.isNotEmpty) {
        buf.write(' ');
        buf.write(s);
      }
    }

    // 标题（字符串或分段）
    try {
      add(item.title);
    } catch (_) {}
    try {
      final list = (item.titleList as List?) ?? (item.title as List?);
      if (list != null) {
        for (final seg in list) {
          try {
            add(seg.text);
          } catch (_) {
            try {
              add(seg['text']);
            } catch (_) {
              add(seg.toString());
            }
          }
        }
      }
    } catch (_) {}

    // 描述/副标题/简介
    try {
      add(item.description);
    } catch (_) {}
    try {
      add(item.desc);
    } catch (_) {}
    try {
      add(item.subTitle);
    } catch (_) {}

    // 标签/分类/风格/地区
    try {
      add(item.tag);
    } catch (_) {}
    try {
      add(item.tags);
    } catch (_) {}
    try {
      add(item.cateName);
    } catch (_) {}
    try {
      add(item.styles);
    } catch (_) {}
    try {
      add(item.areas);
    } catch (_) {}

    // 番剧/PGC 额外
    try {
      add(item.orgTitle);
    } catch (_) {}
    try {
      add(item.indexShow);
    } catch (_) {}
    try {
      add(item.seasonTypeName);
    } catch (_) {}
    try {
      add(item.buttonText);
    } catch (_) {}

    // 用户/UP
    try {
      add(item.uname);
    } catch (_) {}
    try {
      add(item.usign);
    } catch (_) {}
    try {
      add(item.owner?.name);
    } catch (_) {}

    return buf.toString().toLowerCase();
  }

  List _applyFilter(List raw) {
    if (_excludes.isEmpty && _includes.isEmpty) return raw;

    final bool isExact = order == 'exact';
    final List<String> exc = _excludes.map((e) => e.toLowerCase()).toList();
    final List<String> inc = _includes.map((e) => e.toLowerCase()).toList();

    return raw.where((item) {
      final hay = _collectText(item);

      // 排除词：任意命中剔除（始终生效）
      for (final kw in exc) {
        if (kw.isNotEmpty && hay.contains(kw)) return false;
      }

      // 包含词：仅精准模式要求全部命中
      if (isExact && inc.isNotEmpty) {
        for (final kw in inc) {
          if (kw.isEmpty) continue;
          if (!hay.contains(kw)) return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Future<LoadingState<SearchAllData>> customGetData() async {
    final res = await SearchHttp.searchAll(
      keyword: keyword,
      page: page,
      order: order == 'exact' ? '' : order, // 精准不传后端
      duration: null,
      tids: videoZoneType?.tids,
      orderSort: userOrderType?.value.orderSort,
      userType: userType?.value.index,
      categoryId: articleZoneType?.value.categoryId,
      pubBegin: pubBegin,
      pubEnd: pubEnd,
    );

    if (res is Success<SearchAllData>) {
      _parseTerms(keyword);
      final list = res.response.list;
      if (list != null) {
        res.response.list = _applyFilter(list);
      }
    }
    return res;
  }

  void onPushDetail(dynamic resultList) {
    try {
      int? aid = int.tryParse(keyword);
      if (aid != null && resultList.first.aid == aid) {
        PiliScheme.videoPush(aid, null, showDialog: false);
      }
    } catch (_) {}
  }

  void jump2Video() {
    if (IdUtils.avRegexExact.hasMatch(keyword)) {
      hasJump2Video = true;
      PiliScheme.videoPush(
        int.parse(keyword.substring(2)),
        null,
        showDialog: false,
      );
    } else if (IdUtils.bvRegexExact.hasMatch(keyword)) {
      hasJump2Video = true;
      PiliScheme.videoPush(null, keyword, showDialog: false);
    }
  }
}