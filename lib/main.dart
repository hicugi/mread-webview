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
const host = 'http://10.20.40.53:8000';
const homeUrl = '$host/template.html';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

Future<Directory> _getLocaleDir() async {
  Directory main = await getApplicationDocumentsDirectory();
  return main;
}

Future<String> _getHtmlPath() async {
  Directory main = await _getLocaleDir();
  return "${main.path}/index.html";
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

Future<bool> _downloadHtml(String url, String filePath) async {
  File file = File(filePath);

  await http.get(Uri.parse(url)).then((response) {
    return file.writeAsString(response.body);
  });

  return true;
}

Future<void> _syncHtmlTemplate() async {
  debugPrint("============= HTML template: Downloading from server");

  final filePath = await _getHtmlPath();
  await _downloadHtml(homeUrl, filePath);
}

Iterable _getDirSortedItems(dirItems) {
  Iterable result = dirItems.map((v) {
    String alias = v.path.split("/").last;

    RegExp exp = RegExp(r'(^\d+)');
    RegExpMatch? match = exp.firstMatch(alias);

    var n = int.parse(match![0]!);

    return {
      'dir': v,
      'alias': alias,
      'n': n,
    };
  });

  return result.toList()..sort((a, b) => a['n'].compareTo(b['n']));
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
    final filePath = await _getHtmlPath();

    if (!kDebugMode && File(filePath).existsSync()) {
      debugPrint("============= HTML template: Reading from cache");
      return File(filePath).readAsStringSync();
    }

    await _syncHtmlTemplate();
    return File(filePath).readAsStringSync();
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

  String lastManga = "";

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
      ..addJavaScriptChannel('flSyncManga',
          onMessageReceived: (JavaScriptMessage data) async {
        var [name, image] = data.message.split("|");
        Directory mangaDir = await _getMangaDir();

        Directory manga = Directory("${mangaDir.path}/$name");
        if (!manga.existsSync()) {
          manga.createSync(recursive: true);
        }

        String imageUrl = "$host/$image";
        await _downloadImage(imageUrl, "${manga.path}/cover.jpg");
      })

      // select manga
      ..addJavaScriptChannel('flSelectManga',
          onMessageReceived: (JavaScriptMessage data) async {
        var name = data.message;

        lastManga = name;

        Directory mangaDir = await _getMangaDir();
        Directory selMangaDir = Directory("${mangaDir.path}/$name");

        debugPrint("Selected manga: $name");

        Iterable chapters =
            _getDirSortedItems(selMangaDir.listSync().whereType<Directory>());

        for (var i = 0; i < chapters.length; i++) {
          var chapter = chapters.elementAt(i);

          String chapterName = chapter['alias'];
          var chapterInfo = await _getChapterDetails(name, chapterName);

          String dodwnloaded =
              File("${selMangaDir.path}/$chapterName/done").existsSync()
                  ? 'true'
                  : 'false';

          String script =
              "syncChapter('$name', { name: '$chapterName', itemsCount: ${chapterInfo['count']}, size: '${chapterInfo['size']}MB', isDownloaded: $dodwnloaded });";
          _controller.runJavaScript(script);
        }
      })

      // read chapter
      ..addJavaScriptChannel('flSelectChapter',
          onMessageReceived: (JavaScriptMessage data) async {
        var [name, chapter] = data.message.split("|");

        Directory mangaDir = await _getMangaDir();
        Directory chapterDir = Directory("${mangaDir.path}/$name/$chapter");

        // create file
        Directory localDir = await _getLocaleDir();
        File saveFile = File("${localDir.path}/save");

        if (!saveFile.existsSync()) {
          saveFile.create();
        }

        saveFile.writeAsStringSync("$name|$chapter");

        Iterable items = _getDirSortedItems(chapterDir
            .listSync()
            .where((element) => element.path.split('/').last != 'done'));

        for (var i = 0; i < items.length; i++) {
          var item = items.elementAt(i);
          var image = item['dir'];

          String imageBase64 = await _getImageBase64(image.path);

          _controller.runJavaScript(
            "insertImage('$imageBase64');",
          );
        }
      })

      // download chapter
      ..addJavaScriptChannel(
        'flDownloadImage',
        onMessageReceived: (JavaScriptMessage data) async {
          var [path, name, chapter, fileName, imagesCount] =
              data.message.split("|");

          Directory mangaDir = await _getMangaDir();

          var url = "$host/$path";

          String savedDir = "${mangaDir.path}/$name/$chapter";
          Directory(savedDir).createSync(recursive: true);

          debugPrint("Downloading image: $url to $savedDir/$fileName");
          await _downloadImage(url, "$savedDir/$fileName");

          var chapterInfo = await _getChapterDetails(name, chapter);

          if (chapterInfo['count'] == int.parse(imagesCount)) {
            File("$savedDir/done").createSync();
            _controller.runJavaScript(
                "syncChapter('$name', { name: '$chapter', itemsCount: $imagesCount, size: '${chapterInfo['size']}MB', isDownloaded: true });");
          }
        },
      )

      // clear cache
      ..addJavaScriptChannel(
        'flClearCache',
        onMessageReceived: (JavaScriptMessage data) async {
          await _syncHtmlTemplate();
          _controller.reload();
        },
      )
      ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: (String url) async {
        _controller.runJavaScript("window.hostUrl = '$host';");
        await _insertMangaList();

        Directory localDir = await _getLocaleDir();
        File saveFile = File("${localDir.path}/save");

        if (saveFile.existsSync()) {
          var [name, chapter] = saveFile.readAsStringSync().split("|");

          _controller.runJavaScript(
            "currentManga.select('$name');",
          );
          _controller.runJavaScript(
            "setTimeout(() => { chaptersSelElm.value = '$chapter'; currentManga.selectChapter('$chapter'); }, 500);",
          );
        }
      }));
    ;
    // #enddocregion platform_features

    final String htmlBase64 = base64Encode(
      const Utf8Encoder().convert(widget.htmlContent),
    );
    controller.loadRequest(Uri.parse("data:text/html;base64,$htmlBase64"));
    ;

    _controller = controller;
  }

  Future<String> _getImageBase64(String path) async {
    File imageFile = File(path);

    Uint8List imageBytes = await imageFile.readAsBytes();
    String imageBase64 = base64Encode(imageBytes);

    var stat = imageFile.statSync();
    return "data:${stat.type};base64, $imageBase64";
  }

  Future<Map<String, dynamic>> _getChapterDetails(
      String name, String chapter) async {
    Directory mangaDir = await _getMangaDir();

    var path = "${mangaDir.path}/$name/$chapter";
    Directory chapterDir = Directory(path);

    var count = chapterDir.listSync().length;
    double size = 0;

    chapterDir.listSync().forEach((image) {
      size += image.statSync().size;
    });

    return {
      'path': path,
      'size': (size / 1024 / 1024).toStringAsFixed(2),
      'count': count,
    };
  }

  Future<void> _insertMangaList() async {
    Directory mangaDir = await _getMangaDir();

    mangaDir.listSync().forEach((manga) async {
      String name = manga.path.split("/").last;
      String image = await _getImageBase64("${manga.path}/cover.jpg");

      debugPrint("Inserting manga: $name");

      _controller.runJavaScript(
        "insertManga({ name: '$name', image: '$image' });",
      );
    });
  }

  Future<bool> _downloadImage(String url, String filePath) async {
    File file = File(filePath);

    await http.get(Uri.parse(url)).then((response) {
      if (file.existsSync()) {
        if (file.lengthSync() == response.bodyBytes.length) {
          debugPrint(
              "File already exists: $filePath ${response.bodyBytes.length}");
          return;
        }
      }

      file.writeAsBytes(response.bodyBytes);
      debugPrint("Downloaded image: $filePath ${response.bodyBytes.length}");
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
