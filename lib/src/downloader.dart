import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class UnsupportedException extends Error {
  String errMsg() => "Not support range request";
}

class DownloadFailureException extends Error {
  String errMsg() => "Download Failure";
}

class Chunk {
  int partNumber;
  int startOffset;
  int endOffset;
  bool? finished;
  List<int>? data;
  Chunk(this.partNumber, this.startOffset, this.endOffset) {
    finished = false;
    data = <int>[];
  }
  @override
  String toString() {
    return "n:$partNumber, data:${data?.length}";
  }
}

class ProcessState {
  String url;
  int fileSize;
  List<Chunk> chunks = [];
  int successCount;
  int chunkSize;
  ProcessState(
    this.url, {
    this.chunkSize = 0,
    this.fileSize = 0,
    this.successCount = 0,
  }) {
    // _chunkSize = chunkSize;
    // fileSize = 0;
    // successCount = 0;
  }
  init(int size) {
    fileSize = size;
    chunks = <Chunk>[];
    for (var i = 0; i < 600; i++) {
      final startIdx = i * chunkSize;
      var endIdx = (i + 1) * chunkSize;
      if (endIdx > fileSize) {
        endIdx = fileSize;
      }
      this.chunks.add(new Chunk(i + 1, startIdx, endIdx));
      if (endIdx == fileSize) {
        // be sure reach the end of file, quit loop
        break;
      }
    }
  }

  Uint8List asList() {
    final result = <int>[];
    for (var ck in this.chunks) {
      result.addAll(ck.data!);
    }
    return Uint8List.fromList(result);
  }

  @override
  String toString() {
    return "url:${this.url}, size:${this.fileSize}, chunks:${this.chunks}";
  }
}

typedef void OnPercentage(int done, int total);

class Downloader {
  static final Map<String, Downloader> _cache = <String, Downloader>{};
  late ProcessState state;
  late HttpClient client;

  String? downloadUrl;
  StreamController<ProcessState>? controller;
  OnPercentage? _onPercentage;
  int processors = -1;
  bool noError = false;
  bool fetching = false;

  factory Downloader(String url, {int chunkSize = 501001, int p = 2}) {
    return _cache.putIfAbsent(
        url, () => Downloader._internal(url, chunkSize: chunkSize, p: p));
  }

  Downloader._internal(
    String url, {
    int chunkSize = 501001,
    int p = 2,
  }) {
    downloadUrl = url;
    state = ProcessState(url, chunkSize: chunkSize);
    client = new HttpClient();
    processors = p;
    noError = true;
    fetching = false;
  }

  Future<ProcessState> download({OnPercentage? onPercentage}) async {
    _onPercentage = onPercentage;
    final req = await client.headUrl(Uri.parse(state.url));
    final resp = await req.close();
    if (resp.headers['accept-ranges']?.first != 'bytes') {
      throw UnsupportedException();
    }
    final fileSize = int.parse(resp.headers['content-length']!.first);
    this.state.init(fileSize);
    final indexies = List<int>.generate(15, (i) => i);
    fetching = true;
    final futrues = indexies
        .sublist(0, processors)
        .map((pid) => processor(state, pid, processors));
    await Future.wait(futrues);
    fetching = false;
    return state;
  }

  markFinished() {
    _cache.remove(this.downloadUrl);
  }

  Future<Stream<ProcessState>> downStream() async {
    final req = await client.headUrl(Uri.parse(state.url));
    final resp = await req.close();
    if (resp.headers['accept-ranges']?.first != 'bytes') {
      throw UnsupportedException();
    }
    final fileSize = resp.headers.contentLength;
    this.state.init(fileSize);
    controller = new StreamController<ProcessState>();
    final indexies = List<int>.generate(15, (i) => i);
    fetching = true;
    for (var pid in indexies.sublist(0, processors)) {
      processor(state, pid, processors);
    }
    return controller!.stream;
  }

  Future processor(ProcessState state, int pid, int pcount) async {
    for (var chunk in state.chunks) {
      if (chunk.partNumber % pcount == pid) {
        try {
          final st = await downChunk(state, chunk.partNumber - 1);
          if (controller != null) {
            controller!.add(st);
          }
          if (_onPercentage != null) {
            _onPercentage!(st.successCount, st.chunks.length);
          }
        } on DownloadFailureException {
          this.noError = false;
          if (controller != null) {
            print('close stream');
            fetching = false;
            controller?.close();
            _cache.remove(state.url);
            controller = null;
          } else {
            return;
          }
        }
      }
    }
    if (state.successCount == state.chunks.length) {
      if (controller != null) {
        print('close stream');
        fetching = false;
        controller?.close();
      }
    }
  }

  Future<ProcessState> downChunk(ProcessState state, int idx) async {
    Chunk ck = state.chunks[idx];
    HttpClient c = new HttpClient();
    c.connectionTimeout = Duration(seconds: 5);
    final req = await c.getUrl(Uri.parse(state.url));
    req.headers.add('Range', "bytes=${ck.startOffset}-${ck.endOffset - 1}");
    final resp = await req.close();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      for (var ls in await resp.toList()) {
        ck.data?.addAll(ls);
      }
    } else {
      throw DownloadFailureException();
    }
    //print('chunk data: ${ck.data.length}');
    state.successCount++;
    return state;
  }
}
