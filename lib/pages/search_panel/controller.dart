
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/search/article_search_type.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/common/search/user_search_type.dart';
import 'package:PiliPlus/models/common/search/video_search_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/search_result/controller.dart';
import 'package:PiliPlus/utils/extension.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class SearchPanelController<R extends SearchNumData<T>, T>
    extends CommonListController<R, T> {
  SearchPanelController({
    required this.keyword,
    required this.searchType,
    required this.tag,
  });
  final String tag;
  final String keyword;
  final SearchType searchType;

  // sort
  // common
  String order = '';

  // video
  VideoDurationType? videoDurationType; // int duration
  VideoZoneType? videoZoneType; // int? tids;
  int? pubBegin;
  int? pubEnd;

  // user
  Rx<UserOrderType>? userOrderType;
  Rx<UserType>? userType;

  // article
  Rx<ArticleZoneType>? articleZoneType; // int? categoryId;

  SearchResultController? searchResultController;

  void onSortSearch({
    bool getBack = true,
    String? label,
  }) {
    if (getBack) Get.back();
    SmartDialog.dismiss();
    if (label != null) {
      SmartDialog.showToast("「$label」的筛选结果");
    }
    SmartDialog.showLoading(msg: 'loading');
    onReload().whenComplete(SmartDialog.dismiss);
  }

  @override
  void onInit() {
    super.onInit();
    try {
      searchResultController = Get.find<SearchResultController>(tag: tag)
        ..toTopIndex.listen((index) {
          if (index == searchType.index) {
            scrollController.animToTop();
          }
        });
    } catch (_) {}
    queryData();
  }

  @override
  List<T>? getDataList(R response) {
    return response.list;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<R> response) {
    if (isRefresh) {
      searchResultController?.count[searchType.index] =
          response.response.numResults ?? 0;
    }
    return false;
  }

  String? gaiaVtoken;

  // ===== 精准搜索：解析与过滤 =====
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

    // 标题（字符串）
    try {
      add(item.title);
    } catch (_) {}

    // 标题片段（List<({bool isEm, String text})> 或其他）
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

    // 番剧等额外字段
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

    // 用户昵称/签名/UP主名
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

  List<T> _applyFilter(List<T> raw) {
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
  Future<LoadingState<R>> customGetData() async {
    final result = await SearchHttp.searchByType<R>(
      searchType: searchType,
      keyword: keyword,
      page: page,
      // 不向后端传递 exact，仅本地过滤
      order: order == 'exact' ? '' : order,
      duration: videoDurationType?.index,
      tids: videoZoneType?.tids,
      orderSort: userOrderType?.value.orderSort,
      userType: userType?.value.index,
      categoryId: articleZoneType?.value.categoryId,
      pubBegin: pubBegin,
      pubEnd: pubEnd,
      gaiaVtoken: gaiaVtoken,
      onSuccess: (String gaiaVtoken) {
        this.gaiaVtoken = gaiaVtoken;
        queryData(page == 1);
      },
    );

    // 成功后做本地“精准/排除”过滤
    if (result is Success<R>) {
      _parseTerms(keyword);
      final list = getDataList(result.response);
      if (list != null) {
        final filtered = _applyFilter(list);
        result.response.list = filtered;
      }
    }
    return result;
  }

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }
}