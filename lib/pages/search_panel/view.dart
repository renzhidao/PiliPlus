
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/refresh_indicator.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/search_panel/controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

abstract class CommonSearchPanel extends StatefulWidget {
  const CommonSearchPanel({
    super.key,
    required this.keyword,
    required this.searchType,
    required this.tag,
  });

  final String keyword;
  final SearchType searchType;
  final String tag;
}

abstract class CommonSearchPanelState<
  S extends CommonSearchPanel,
  R extends SearchNumData<T>,
  T
> extends State<S> with AutomaticKeepAliveClientMixin {
  SearchPanelController<R, T> get controller;

  @override
  bool get wantKeepAlive => true;

  Widget? buildExactBar(ThemeData theme) {
    // 视频面板自带筛选条，非视频类型添加“精准”开关
    if (widget.searchType == SearchType.video) return null;

    final bool isExact = controller.order == 'exact';
    return SliverToBoxAdapter(
      child: Container(
        width: double.infinity,
        height: 36,
        padding: const EdgeInsets.only(left: 8, right: 12),
        color: theme.colorScheme.surface,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            label: const Text('精准'),
            selected: isExact,
            showCheckmark: false,
            labelStyle: TextStyle(
              color: isExact
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            selectedColor: Colors.transparent,
            backgroundColor: Colors.transparent,
            side: BorderSide.none,
            onSelected: (selected) async {
              setState(() {
                controller.order = selected ? 'exact' : '';
              });
              await controller.onReload();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return refreshIndicator(
      onRefresh: controller.onRefresh,
      child: CustomScrollView(
        controller: controller.scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          ?buildHeader(theme),
          ?buildExactBar(theme),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
            ),
            sliver: Obx(() => _buildBody(theme, controller.loadingState.value)),
          ),
        ],
      ),
    );
  }

  Widget get buildLoading;

  Widget _buildBody(ThemeData theme, LoadingState<List<T>?> loadingState) {
    return switch (loadingState) {
      Loading() => buildLoading,
      Success(:var response) =>
        response?.isNotEmpty == true
            ? buildList(theme, response!)
            : HttpError(onReload: controller.onReload),
      Error(:var errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget? buildHeader(ThemeData theme) => null;

  Widget buildList(ThemeData theme, List<T> list);
}