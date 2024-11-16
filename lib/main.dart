import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

// For downloading files
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

// For the File type
import 'dart:io';
import 'dart:convert';
import 'dart:async';

// 10.0.2.2 bind with localhost
// const bool _isDebug = bool.fromEnvironment('dart.vm.product') == false;
String host = '';
String ADDR_URL = 'http://mread.webmaho.com/appHost.php';

const chaptersSyncTimeout = Duration(milliseconds: 300);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

void innerDebug(String value) {
  debugPrint("===================== $value");
}

Future<Directory> _getLocaleDir() async {
  Directory main = await getApplicationDocumentsDirectory();
  return main;
}

Future<File> _getHtmlFile() async {
  Directory main = await _getLocaleDir();
  return File("${main.path}/index.html");
}
Future<File> _getAddrFile() async {
  Directory main = await _getLocaleDir();
  return File("${main.path}/addr");
}

Future<Directory> _getMangaDir() async {
  Directory main = await _getLocaleDir();
  var result = Directory("${main.path}/manga");

  var isExist = await result.exists();
  if (!isExist) {
    result.createSync(recursive: true);
  }

  return result;
}

Future<String> _getImageBase64(String path) async {
  File imageFile = File(path);

  Uint8List imageBytes = await imageFile.readAsBytes();
  String imageBase64 = base64Encode(imageBytes);

  var stat = imageFile.statSync();
  return "data:${stat.type};base64, $imageBase64";
}

Future<bool> _downloadHtml(String url, String filePath) async {
  File file = File(filePath);

  innerDebug("Downloading html $filePath from $url");

  await http.get(Uri.parse(url)).then((response) {
    return file.writeAsString(response.body);
  });

  return true;
}

Future<void> _syncHtmlTemplate() async {
  File hostFile = await _getAddrFile();
  File htmlFile = await _getHtmlFile();

  innerDebug("Syncing html template");

  await http.get(Uri.parse(ADDR_URL)).then((response) async {
    host = response.body;
    hostFile.writeAsString(host);

    innerDebug("Updating cache for HTML ${host}");

    await _downloadHtml("${host}/template.html", htmlFile.path);
  });
}

Iterable _getDirSortedItems(dirItems) {
  Iterable result = dirItems.map((v) {
    String alias = v.path.split("/").last;

    RegExp exp = RegExp(r'(^\d+)');
    RegExpMatch? match = exp.firstMatch(alias);

    var n = double.parse(match![0]!);
    var n2 = alias.split('-');

    if (n2.length > 1) {
      n += double.parse(n2[1]) / 100000;
    }

    return {
      'dir': v,
      'alias': alias,
      'n': n,
    };
  });

  return result.toList()..sort((a, b) => a['n'].compareTo(b['n']));
}

Future<Map<String, dynamic>> _getChapterDetails(
    String name, String chapter) async {
  Directory mangaDir = await _getMangaDir();

  var path = "${mangaDir.path}/$name/$chapter";
  Directory chapterDir = Directory(path);

  var count = chapterDir.listSync().length;

  return {
    'path': path,
    'count': count,
  };
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MRead',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
      ),
      home: MyWebView(),
    );
  }
}

class MyWebView extends StatefulWidget {
  @override
  _ParentWidgetState createState() => _ParentWidgetState();
}

class _ParentWidgetState extends State<MyWebView> {
  Future htmlContent = Future.value();

  Future<String> _getHtml() async {
    File fileHtml = await _getHtmlFile();

    if (!kDebugMode && fileHtml.existsSync()) {
      File file = await _getAddrFile();
      host = file.readAsStringSync();

      innerDebug("HTML template: Reading from cache");
      return fileHtml.readAsStringSync();
    }

    await _syncHtmlTemplate();

    File fileRes = await _getHtmlFile();
    return fileRes.readAsStringSync();
  }

  @override
  void initState() {
    super.initState();
    htmlContent = _getHtml();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: htmlContent,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return ChildWidget(htmlContent: snapshot.data);
          }

          const result =
              Scaffold(body: Center(child: CircularProgressIndicator()));
          return result;
        });
  }
}

class ChildWidget extends StatefulWidget {
  final htmlContent;

  ChildWidget({this.htmlContent});

  @override
  _MyWebViewState createState() => _MyWebViewState();
}

class _MyWebViewState extends State<ChildWidget> {
  late final WebViewController _controller;
  String htmlContent = "";
  bool isHtmlLoaded = false;
  num flSelectMangaLastId = 0;

  @override
  void initState() {
    super.initState();

    // #docregion platform_features
    late final PlatformWebViewControllerCreationParams params;
    params = const PlatformWebViewControllerCreationParams();

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);
    // #enddocregion platform_features

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))

      // Toaster
      ..addJavaScriptChannel(
        'Toaster',
        onMessageReceived: (JavaScriptMessage message) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message.message)),
          );
        },
      )

      // sync manga
      ..addJavaScriptChannel(
        'flFetchMangaList',
        onMessageReceived: (JavaScriptMessage data) async {
          _controller.runJavaScript("flSetHost('${host}');");
          await _insertMangaList();
        },
      )
      ..addJavaScriptChannel('flSyncManga',
          onMessageReceived: (JavaScriptMessage data) async {
        var [name, url] = data.message.split("|");
        Directory mangaDir = await _getMangaDir();

        innerDebug("$name $url ${mangaDir.path}");

        Directory manga = Directory("${mangaDir.path}/$name");
        if (!manga.existsSync()) {
          manga.createSync(recursive: true);
        }

        await _downloadImage(url, "${manga.path}/cover.jpg");
        await _insertMangaList();
      })

      // select manga
      ..addJavaScriptChannel('flSelectManga',
          onMessageReceived: (JavaScriptMessage data) {
        _syncChapters(data.message);
      })

      // read chapter
      ..addJavaScriptChannel('flInsertImgsFromChapter',
          onMessageReceived: (JavaScriptMessage data) async {
        var [name, chapter] = data.message.split("|");

        Directory mangaDir = await _getMangaDir();
        Directory chapterDir = Directory("${mangaDir.path}/$name/$chapter");

        // create save file
        File saveFile = File("${mangaDir.path}/save");

        if (!saveFile.existsSync()) {
          saveFile.create();
        }

        saveFile.writeAsStringSync(chapter);
        innerDebug("Last readed chapter $chapter");

        Iterable items = _getDirSortedItems(chapterDir
            .listSync()
            .where((element) => element.path.split('/').last != 'done'));

        for (var i = 0; i < items.length; i++) {
          var item = items.elementAt(i);
          var image = item['dir'];

          String imageBase64 = await _getImageBase64(image.path);

          _controller.runJavaScript(
            "flInsertImage('$imageBase64');",
          );
        }
      })

      // download chapter
      ..addJavaScriptChannel(
        'flDownloadImage',
        onMessageReceived: (JavaScriptMessage data) async {
          var [url, name, chapter, fileName, imagesCount] =
              data.message.split("|");

          Directory mangaDir = await _getMangaDir();

          String savedDir = "${mangaDir.path}/$name/$chapter";
          Directory(savedDir).createSync(recursive: true);

          // check if image is exist
          // if (!File("$savedDir/$fileName").existsSync()) {}
          await _downloadImage(url, "$savedDir/$fileName");

          _controller.runJavaScript("flImageDownloaded();");

          var chapterInfo = await _getChapterDetails(name, chapter);

          innerDebug(
              "Downloading image (${chapterInfo['count']}/$imagesCount) from $url");
        },
      )

      // clear cache
      ..addJavaScriptChannel(
        'flRemoveAll',
        onMessageReceived: (JavaScriptMessage data) async {
          Directory parent = await _getMangaDir();
          await parent.delete(recursive: true);

          await _syncHtmlTemplate();
          _controller.reload();
        },
      )
      ..addJavaScriptChannel(
        'flClearCache',
        onMessageReceived: (JavaScriptMessage data) async {
          await _syncHtmlTemplate();
          _controller.reload();
        },
      )
      ..addJavaScriptChannel(
        'flRemoveManga',
        onMessageReceived: (JavaScriptMessage data) async {
          Directory parent = await _getMangaDir();
          Directory mangaDir = Directory("${parent.path}/${data.message}");
          await mangaDir.delete(recursive: true);

          await _controller.reload();
          await _insertMangaList();
        },
      )
      ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: (String url) async {
            // Web page loaded
      }));
    ;
    // #enddocregion platform_features

    final String htmlBase64 = base64Encode(
      const Utf8Encoder().convert(widget.htmlContent),
    );
    controller.loadRequest(Uri.parse("data:text/html;base64,$htmlBase64"));

    _controller = controller;
  }

  Future<void> _insertMangaList() async {
    Directory mangaDir = await _getMangaDir();

    _controller.runJavaScript("flSyncMangaList([]);");

    mangaDir.listSync().forEach((manga) async {
      String name = manga.path.split("/").last;
      String image = await _getImageBase64("${manga.path}/cover.jpg");

      innerDebug("Inserting locale manga: $name");

      String savedChapter = '';
      File saveFile = File("${manga.path}/save");

      if (saveFile.existsSync()) {
        String chapter = saveFile.readAsStringSync();
        savedChapter = ", currentChapter: '$chapter'";
      }

      String insertData = "{ name: '$name', image: '$image'$savedChapter }";
      _controller.runJavaScript("flInsertManga($insertData);");
    });
  }

  Future<void> _syncChapters(String name) async {
    flSelectMangaLastId = (flSelectMangaLastId + 1) % 255;
    num currentId = flSelectMangaLastId;

    await Future.delayed(chaptersSyncTimeout);

    if (currentId != flSelectMangaLastId) return;

    Directory mangaDir = await _getMangaDir();
    Directory selMangaDir = Directory("${mangaDir.path}/$name");

    if (!selMangaDir.existsSync()) {
      return;
    }

    File saveFile = File("${mangaDir.path}/save");
    String lastReadedChapter = "";

    if (saveFile.existsSync()) {
      lastReadedChapter = saveFile.readAsStringSync();
    }

    innerDebug("Selected manga: $name");

    Iterable chapters =
        _getDirSortedItems(selMangaDir.listSync().whereType<Directory>());

    List<String> jsData = [];

    for (var i = 0; i < chapters.length; i++) {
      var chapter = chapters.elementAt(i);

      String chapterName = chapter['alias'];
      var chapterInfo = await _getChapterDetails(name, chapterName);

      String continueValue =
          lastReadedChapter == chapterName ? 'true' : 'false';

      jsData.add(
          "{ name: '$chapterName', itemsCount: ${chapterInfo['count']}, isDownloaded: true, isContinue: $continueValue }");
    }

    _controller.runJavaScript("flSyncChapters([${jsData.join(',')}]);");
  }

  Future<bool> _downloadImage(String url, String filePath) async {
    File file = File(filePath);

    await http.get(Uri.parse(url)).then((response) {
      if (file.existsSync()) {
        if (file.lengthSync() == response.bodyBytes.length) {
          innerDebug(
              "File already exists: $filePath ${response.bodyBytes.length}");
          return;
        }
      }

      file.writeAsBytes(response.bodyBytes);
      innerDebug("Downloaded image: $filePath ${response.bodyBytes.length}");
    });

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: WebViewWidget(controller: _controller),
    );
  }
}
