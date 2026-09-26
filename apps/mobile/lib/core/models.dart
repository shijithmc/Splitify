typedef Json = Map<String, dynamic>;
List<Json> rows(dynamic values) => (values as List? ?? [])
    .map((v) => Map<String, dynamic>.from(v as Map))
    .toList();
Json object(dynamic value) =>
    value == null ? {} : Map<String, dynamic>.from(value as Map);

class Member {
  final String id, name;
  final String? userId;
  final bool placeholder, deleted, left, external, externalReviewDue;
  Member.from(Json j)
    : id = j['id'],
      name = j['displayName'],
      userId = j['userId'],
      placeholder = j['isPlaceholder'] ?? false,
      deleted = j['isDeleted'] ?? false,
      external = j['isExternal'] ?? false,
      externalReviewDue = j['externalReviewDue'] ?? false,
      left = j['hasLeft'] ?? false;
}

class Group {
  final String id, name, type;
  final int version, count, net;
  final bool archived;
  final List<Member> members;
  final List<Json> balances;
  final String? creatorId;
  Group.from(Json j)
    : id = j['id'],
      name = j['name'],
      type = j['type'],
      version = j['version'],
      count = j['memberCount'] ?? (j['members'] as List? ?? []).length,
      net = j['netPaise'] ?? 0,
      archived = j['archived'] ?? false,
      members = rows(j['members']).map(Member.from).toList(),
      balances = rows(j['balances']),
      creatorId = j['creatorId'];
  String memberName(String id) =>
      members
          .where((m) => m.id == id)
          .map((m) => m.deleted ? 'Deleted user' : m.name)
          .firstOrNull ??
      'Former member';
  String? participant(String userId) =>
      members.where((m) => m.userId == userId).firstOrNull?.id;
  int netFor(String id) =>
      balances
          .where((b) => b['participantId'] == id)
          .firstOrNull?['netPaise'] ??
      0;
  Map<String, int> pairs(String id) => object(
    balances
        .where((b) => b['participantId'] == id)
        .firstOrNull?['counterparties'],
  ).map((k, v) => MapEntry(k, v as int));
}

class Expense {
  final Json json;
  Expense(this.json);
  String get id => json['id'];
  String get description => json['description'];
  int get amount => json['amountPaise'];
  int get version => json['version'];
  String get payer => json['payerId'];
  String get date => json['date'];
  String get mode => json['mode'];
  bool get deleted => json['deletedAt'] != null;
  List<Json> get participants => rows(json['participants']);
  Map<String, int> get shares =>
      object(json['shares']).map((k, v) => MapEntry(k, v as int));
}

class ApiFailure implements Exception {
  final String message, code;
  final int status;
  ApiFailure(this.message, {this.code = 'unknown', this.status = 0});
  @override
  String toString() => message;
}
