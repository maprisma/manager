import 'package:maprisma_manager_core/maprisma_manager_core.dart';

/// Calls a core route: the Backend isolate in the app, the core itself in tests.
typedef CoreCall = Future<Map<String, dynamic>> Function(String method, [Map<String, dynamic> params]);

/// The core in this isolate (tests): its refusals as the Backend reports them.
CoreCall inProcess(CoreService core) => (method, [params = const {}]) async {
  try {
    return await core.call(method, params);
  } on RouteError catch (e) {
    throw ServiceError(e.code, e.message);
  }
};
