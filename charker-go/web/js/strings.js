// ============================================================================
// Charker — base string table (owner: web-shell)
//
// Convention (spec-ui §6.2): the **Chinese source string is the key**, and the
// value is what the UI shows. `t(key, ...args)` supports the Swift format
// specifiers `%@ %d %.1f %s %%` and the object form `t('{n} 个端口', {n})`.
// English copy is verbatim from the shipped `en.lproj` tables where the key is
// in the curated list (spec-ui §6.4); Windows re-wordings follow §6.5.
//
// THIS FILE IS SHELL + SHARED COPY ONLY. Screen owners must NOT append here —
// they ship a separate table that i18n.js merges over these keys at boot:
//   web/js/strings-overview.js   (owner: web-overview)
//   web/js/strings-screens.js    (owner: web-screens)
// Each exports `{zh: {…}, en: {…}}` (named export or default). Merge semantics
// are per-key `{...base.zh, ...ext.zh}` so shell keys can never be erased.
// ============================================================================

export const STRINGS = {
  zh: {
    // --- shell: sidebar / navigation -------------------------------------
    总览: '总览',
    能耗记录: '能耗记录',
    设备与连接: '设备与连接',
    菜单栏: '菜单栏',
    'Apple 家庭': 'Apple 家庭',
    高级: '高级',
    关于: '关于',
    演示模式: '演示模式',
    退出: '退出',
    '退出 Charker': '退出 Charker',
    开发构建: '开发构建',
    '打开「设备与连接」': '打开「设备与连接」',
    连接状态: '连接状态',
    设备: '设备',

    // --- shell: phases / status ------------------------------------------
    未连接: '未连接',
    已连接: '已连接',
    搜索中: '搜索中',
    连接中: '连接中',
    握手中: '握手中',
    重连中: '重连中',
    连接失败: '连接失败',
    '正在扫描…': '正在扫描…',
    设备连接已断开: '设备连接已断开',
    无数据: '无数据',
    已关闭: '已关闭',
    待机: '待机',
    未接入设备: '未接入设备',

    // --- shell: route chrome ---------------------------------------------
    '实时功率、端口状态与能耗概览': '实时功率、端口状态与能耗概览',
    '用电统计、趋势与会话记录': '用电统计、趋势与会话记录',
    '蓝牙连接、设备设置与附近设备': '蓝牙连接、设备设置与附近设备',
    '菜单栏读数样式与预设': '菜单栏读数样式与预设',
    '外观、启动、诊断与实验选项': '外观、启动、诊断与实验选项',
    '版本信息与开源项目': '版本信息与开源项目',

    // --- shell: notices / errors / placeholder ---------------------------
    关闭: '关闭',
    重新加载: '重新加载',
    返回总览: '返回总览',
    页面渲染出错: '页面渲染出错',
    '发生了一个错误：%@': '发生了一个错误：%@',
    '操作失败：%@': '操作失败：%@',
    建设中: '建设中',
    该页面正在建设中: '该页面正在建设中',
    页面模块由其他同学实现: '该页面模块将在后续合并中接入，外壳与导航已可正常使用。',
    未知错误: '未知错误',
    更多: '更多',
    重试: '重试',

    // --- shared: common controls -----------------------------------------
    取消: '取消',
    确定: '确定',
    保存: '保存',
    应用: '应用',
    删除: '删除',
    编辑: '编辑',
    添加: '添加',
    设置: '设置',
    搜索: '搜索',
    扫描: '扫描',
    重新扫描: '重新扫描',
    连接: '连接',
    断开连接: '断开连接',
    重新连接: '重新连接',
    复制: '复制',
    已复制: '已复制',
    复制完整序列号: '复制完整序列号',
    语言: '语言',
    主题: '主题',
    窗口外观: '窗口外观',
    跟随系统: '跟随系统',
    浅色: '浅色',
    深色: '深色',
    中文: '中文',
    English: 'English',
    打开主窗口: '打开主窗口',
    在资源管理器中显示: '在资源管理器中显示',
    软件更新: '软件更新',
    '检查更新…': '检查更新…',
    登录时启动: '登录时启动',
    轮询间隔: '轮询间隔',
    允许端口开关: '允许端口开关',
    记录原始报文: '记录原始报文',
    '导出诊断…': '导出诊断…',
    '演示模式（模拟充电器）': '演示模式（模拟充电器）',
    '版本 %@': '版本 %@',

    // --- shared: units / time --------------------------------------------
    秒: '秒',
    分钟: '分钟',
    小时: '小时',
    天: '天',
    '%ds': '%ds',
    '%dm': '%dm',
    '%dh%dm': '%dh%dm',
    '%d天 %d小时': '%d天 %d小时',
    今天: '今天',
    昨天: '昨天',
    '正在扫描附近设备…': '正在扫描附近设备…',

    // --- shared: data labels ---------------------------------------------
    实时总输出: '实时总输出',
    功率时间线: '功率时间线',
    端口: '端口',
    已选: '已选',
    '已选 C%d': '已选 C%d',
    指针移到图上查看任意时刻: '指针移到图上查看任意时刻',
    峰值: '峰值',
    平均: '平均',
    本次能量: '本次能量',
    连接时长: '连接时长',
    本次: '本次',
    本周: '本周',
    本月: '本月',
    全部: '全部',
    暂无数据: '暂无数据',
    '正在积累功率曲线…': '正在积累功率曲线…',
    连接后开始记录功率曲线: '连接后开始记录功率曲线',
    查看能耗记录: '查看能耗记录',
    结束本次统计: '结束本次统计',
    清理记录: '清理记录',
    导出: '导出',
    打开端口: '打开端口',
    关闭端口: '关闭端口',
    已保存: '已保存',
    已连接设备: '已连接设备',
  },

  en: {
    // --- shell: sidebar / navigation -------------------------------------
    总览: 'Overview',
    能耗记录: 'Energy',
    设备与连接: 'Devices & Connection',
    菜单栏: 'Menu Bar',
    'Apple 家庭': 'Apple Home',
    高级: 'Advanced',
    关于: 'About',
    演示模式: 'Demo Mode',
    退出: 'Exit',
    '退出 Charker': 'Exit Charker',
    开发构建: 'Development Build',
    '打开「设备与连接」': 'Open Devices & Connection',
    连接状态: 'Connection Status',
    设备: 'Device',

    // --- shell: phases / status ------------------------------------------
    未连接: 'Not Connected',
    已连接: 'Connected',
    搜索中: 'Searching',
    连接中: 'Connecting',
    握手中: 'Handshaking',
    重连中: 'Reconnecting',
    连接失败: 'Connection Failed',
    '正在扫描…': 'Scanning…',
    设备连接已断开: 'Device connection lost',
    无数据: 'No Data',
    已关闭: 'Off',
    待机: 'Standby',
    未接入设备: 'No Device Connected',

    // --- shell: route chrome ---------------------------------------------
    '实时功率、端口状态与能耗概览': 'Live power, port status and energy at a glance',
    '用电统计、趋势与会话记录': 'Totals, trends and charging sessions',
    '蓝牙连接、设备设置与附近设备': 'Bluetooth connection, device settings and nearby devices',
    '菜单栏读数样式与预设': 'Menu-bar readout styles and presets',
    '外观、启动、诊断与实验选项': 'Appearance, startup, diagnostics and experiments',
    '版本信息与开源项目': 'Version information and open-source links',

    // --- shell: notices / errors / placeholder ---------------------------
    关闭: 'Close',
    重新加载: 'Reload',
    返回总览: 'Back to Overview',
    页面渲染出错: 'This page failed to render',
    '发生了一个错误：%@': 'Something went wrong: %@',
    '操作失败：%@': 'Operation failed: %@',
    建设中: 'Under Construction',
    该页面正在建设中: 'This page is under construction',
    页面模块由其他同学实现: 'The screen module is merged in a later step; the shell and navigation already work.',
    未知错误: 'Unknown error',
    更多: 'More',
    重试: 'Retry',

    // --- shared: common controls -----------------------------------------
    取消: 'Cancel',
    确定: 'OK',
    保存: 'Save',
    应用: 'Apply',
    删除: 'Delete',
    编辑: 'Edit',
    添加: 'Add',
    设置: 'Settings',
    搜索: 'Search',
    扫描: 'Scan',
    重新扫描: 'Scan Again',
    连接: 'Connect',
    断开连接: 'Disconnect',
    重新连接: 'Reconnect',
    复制: 'Copy',
    已复制: 'Copied',
    复制完整序列号: 'Copy Full Serial Number',
    语言: 'Language',
    主题: 'Theme',
    窗口外观: 'Window Appearance',
    跟随系统: 'System',
    浅色: 'Light',
    深色: 'Dark',
    中文: 'Chinese',
    English: 'English',
    打开主窗口: 'Open Main Window',
    在资源管理器中显示: 'Show in File Explorer',
    软件更新: 'Software Updates',
    '检查更新…': 'Check for Updates…',
    登录时启动: 'Launch at Login',
    轮询间隔: 'Polling Interval',
    允许端口开关: 'Allow Port Switching',
    记录原始报文: 'Capture Raw Packets',
    '导出诊断…': 'Export Diagnostics…',
    '演示模式（模拟充电器）': 'Demo Mode (Simulated Charger)',
    '版本 %@': 'Version %@',

    // --- shared: units / time --------------------------------------------
    秒: 's',
    分钟: 'min',
    小时: 'h',
    天: 'd',
    '%ds': '%ds',
    '%dm': '%dm',
    '%dh%dm': '%dh%dm',
    '%d天 %d小时': '%dd %dh',
    今天: 'Today',
    昨天: 'Yesterday',
    '正在扫描附近设备…': 'Scanning for nearby devices…',

    // --- shared: data labels ---------------------------------------------
    实时总输出: 'Live Total Output',
    功率时间线: 'Power Timeline',
    端口: 'Port',
    已选: 'Selected',
    '已选 C%d': 'C%d Selected',
    指针移到图上查看任意时刻: 'Hover the chart to inspect any moment',
    峰值: 'Peak',
    平均: 'Average',
    本次能量: 'Session Energy',
    连接时长: 'Connected Time',
    本次: 'Session',
    本周: 'This Week',
    本月: 'This Month',
    全部: 'All',
    暂无数据: 'No Data Yet',
    '正在积累功率曲线…': 'Building the Power Curve…',
    连接后开始记录功率曲线: 'Connect to Start Recording the Power Curve',
    查看能耗记录: 'View Energy History',
    结束本次统计: 'End Current Session',
    清理记录: 'Clear History',
    导出: 'Export',
    打开端口: 'Turn On',
    关闭端口: 'Turn Off',
    已保存: 'Saved',
    已连接设备: 'Connected Device',
  },
};

// ---------------------------------------------------------------------------
// Extension tables (NOT in this file — see the header):
//   // --- screens: overview ---  web/js/strings-overview.js (owner web-overview)
//   // --- screens: energy   ---  web/js/strings-screens.js  (owner web-screens)
//   // --- screens: devices  ---          ↑ same file, one table per owner
//   // --- screens: menubar  ---
//   // --- screens: advanced ---
//   // --- screens: about    ---
// i18n.js merges them per key, extension wins, at boot.
// ---------------------------------------------------------------------------

export default STRINGS;
