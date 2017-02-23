part of angel_mongo.services;

/// Manipulates data from MongoDB as Maps.
class MongoService extends Service {
  DbCollection collection;

  /// If set to `true`, clients can remove all items by passing a `null` `id` to `remove`.
  ///
  /// `false` by default.
  final bool allowRemoveAll;

  /// If set to `true`, parameters in `req.query` are applied to the database query.
  final bool allowQuery;

  final bool debug;

  MongoService(DbCollection this.collection,
      {this.allowRemoveAll: false, this.allowQuery: true, this.debug: true})
      : super();

  SelectorBuilder _makeQuery([Map params_]) {
    Map params = params_ ?? {};
    params = params..remove('provider');
    SelectorBuilder result = where.exists('_id');

    // You can pass a SelectorBuilder as 'query';
    if (params['query'] is SelectorBuilder) {
      return params['query'];
    }

    for (var key in params.keys) {
      if (key == r'$sort' ||
          key == r'$query' &&
              (allowQuery == true || !params.containsKey('provider'))) {
        if (params[key] is Map) {
          // If they send a map, then we'll sort by every key in the map
          for (String fieldName in params[key].keys.where((x) => x is String)) {
            var sorter = params[key][fieldName];
            if (sorter is num) {
              result = result.sortBy(fieldName, descending: sorter == -1);
            } else if (sorter is String) {
              result = result.sortBy(fieldName, descending: sorter == "-1");
            } else if (sorter is SelectorBuilder) {
              result = result.and(sorter);
            }
          }
        } else if (params[key] is String && key == r'$sort') {
          // If they send just a string, then we'll sort
          // by that, ascending
          result = result.sortBy(params[key]);
        }
      } else if (key == 'query' &&
          (allowQuery == true || !params.containsKey('provider'))) {
        Map query = params[key];
        query.forEach((key, v) {
          var value = v is Map ? _filterNoQuery(v) : v;

          if (!_NO_QUERY.contains(key) &&
              value is! RequestContext &&
              value is! ResponseContext) {
            result = result.and(where.eq(key, value));
          }
        });
      }
    }

    return result;
  }

  _jsonify(Map doc, [Map params]) {
    Map result = {};

    for (var key in doc.keys) {
      var value = doc[key];
      if (value is ObjectId) {
        result[key] = value.toHexString();
      } else if (value is! RequestContext && value is! ResponseContext) {
        result[key] = value;
      }
    }

    return _transformId(result);
  }

  void printDebug(e, st, msg) {
    if (debug) {
      stderr.writeln('$msg ERROR: $e');
      stderr.writeln(st);
    }
  }

  @override
  Future<List> index([Map params]) async {
    return await (await collection.find(_makeQuery(params)))
        .map((x) => _jsonify(x, params))
        .toList();
  }

  @override
  Future create(data, [Map params]) async {
    Map item = (data is Map) ? data : god.serializeObject(data);
    item = _removeSensitive(item);

    try {
      item['createdAt'] = new DateTime.now().toIso8601String();
      await collection.insert(item);
      return await _lastItem(collection, _jsonify, params);
    } catch (e, st) {
      printDebug(e, st, 'CREATE');
      throw new AngelHttpException(e, stackTrace: st);
    }
  }

  @override
  Future read(id, [Map params]) async {
    ObjectId _id = _makeId(id);
    Map found = await collection.findOne(where.id(_id).and(_makeQuery(params)));

    if (found == null) {
      throw new AngelHttpException.notFound(
          message: 'No record found for ID ${_id.toHexString()}');
    }

    return _jsonify(found, params);
  }

  @override
  Future modify(id, data, [Map params]) async {
    var target = await read(id, params);
    Map result = mergeMap([
      target is Map ? target : god.serializeObject(target),
      _removeSensitive(data)
    ]);
    result['updatedAt'] = new DateTime.now().toIso8601String();

    try {
      await collection.update(where.id(_makeId(id)), result);
      result = _jsonify(result, params);
      result['id'] = id;
      return result;
    } catch (e, st) {
      printDebug(e, st, 'MODIFY');
      throw new AngelHttpException(e, stackTrace: st);
    }
  }

  @override
  Future update(id, data, [Map params]) async {
    var target = await read(id, params);
    Map result = _removeSensitive(data);
    result['_id'] = _makeId(id);
    result['createdAt'] =
        target is Map ? target['createdAt'] : target.createdAt;

    if (result['createdAt'] is DateTime)
      result['createdAt'] = result['createdAt'].toIso8601String();

    result['updatedAt'] = new DateTime.now().toIso8601String();

    try {
      await collection.update(where.id(_makeId(id)), result);
      result = _jsonify(result, params);
      result['id'] = id;
      return result;
    } catch (e, st) {
      printDebug(e, st, 'UPDATE');
      throw new AngelHttpException(e, stackTrace: st);
    }
  }

  @override
  Future remove(id, [Map params]) async {
    if (id == null ||
        id == 'null' &&
            (allowRemoveAll == true ||
                params?.containsKey('provider') != true)) {
      await collection.remove(null);
      return {};
    }

    var result = await read(id, params);

    try {
      await collection.remove(where.id(_makeId(id)).and(_makeQuery(params)));
      return result;
    } catch (e, st) {
      printDebug(e, st, 'REMOVE');
      throw new AngelHttpException(e, stackTrace: st);
    }
  }
}
