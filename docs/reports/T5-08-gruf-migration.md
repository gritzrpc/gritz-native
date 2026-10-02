# T5-08: 公式gruf-demoのRPC移行比較

2026-10-02、Gruf 2.22.0とGritzの互換Controllerで、公式gruf-demoのProductsサービスを実際に起動して比較した。
LinuxとmacOSで9ケースが成功し、4種類のRPCの値・順序、NotFoundのステータス・メッセージ・JSON、Basic認証の拒否が一致した。
ProductsControllerの変更は継承先1行だけである。

## 原典と変更範囲

Grufの[公式README](https://github.com/bigcommerce/gruf#demo-rails-app)が紹介する[bigcommerce/gruf-demo](https://github.com/bigcommerce/gruf-demo)を使用した。
参照元は次の固定commitで、取得した元ファイルのURL・SHA256を[fixtureのSOURCES.json](../../spec/integration/gruf/fixtures/upstream/SOURCES.json)に保存している。
各ファイルのSHA256とMITライセンスを実テストで確認する。

| 対象 | 固定commit |
| --- | --- |
| Gruf v2.22.0 | `5c843adeeb4f59c0999edee500e024bc69caaf0f` |
| gruf-demo | `4381b12192fdc9e5e00da89c4b1fd41c77857044` |

Product、ApplicationRecord、生成済みprotobuf、Controllerの元ファイルをそのまま使用する。
移行先Controllerは`Gruf::Controllers::Base`を`Gritz::Compat::Gruf::Controller`へ変更したものと完全一致する。
Gruf組み込みBasic認証のソースは、移行先namespaceと継承先を変更し、認証処理を維持した。
元のGrufプロセスと移行先プロセスは独立したRuby subprocessで起動する。
移行先では`::Gruf`が未定義であることも確認した。

データベースはテストごとのSQLiteを使い、実際のActiveRecordモデルと同じ商品2件を準備する。
元アプリケーション全体のRails起動、MySQL、画面はこの比較に含まれない。
モデルのpresence validationは両プロセスで同じエラーメッセージを返すが、元の作成RPCは`Product.new`を変換するだけで保存・validationを実行しない。
このモデル検証をRPCの入力エラー検証とは扱わない。

## 検証結果と再現コマンド

| 対象 | 環境 | 結果 |
| --- | --- | --- |
| 実Gruf・Gritz移行比較 | Linux、Ruby 3.4.11、grpc 1.83.0、ActiveRecord 8.1.4 | 9 examples、0 failures、2.52秒 |
| 実Gruf・Gritz移行比較 | macOS、Ruby 4.0.6、grpc 1.83.0、ActiveRecord 8.1.4 | 9 examples、0 failures、2.23秒 |
| Core互換API・設定変換 | Linux、Ruby 3.4.11 | 22 examples、0 failures。Core全187件も成功 |
| Core互換API・設定変換 | macOS、Ruby 4.0.6 | 22 examples、0 failures。Core全187件も成功 |

Linuxの既存コンテナ`gritz-t2-test`で以下を実行した。
`tmp/phase5.Gemfile`は3つのGritz GemとRails統合をローカルpathで読み、検証用にGruf 2.22.0、ActiveRecord、SQLite、RSpecを含む非公開Bundleである。
再現時は同じ依存を準備して`BUNDLE_GEMFILE`を置き換える。
Gruf・ActiveRecord・SQLiteは互換レイヤの実行時依存には追加していない。

```sh
docker exec -e BUNDLE_GEMFILE=/workspace/gritz-native/tmp/phase5.Gemfile \
  -w /workspace/gritz-native gritz-t2-test \
  bundle exec rspec spec/integration/gruf/migration_spec.rb

docker exec -e BUNDLE_GEMFILE=/workspace/gritz-native/tmp/phase5.Gemfile \
  -w /workspace/gritz-core gritz-t2-test \
  bundle exec rspec spec/gruf_compat_spec.rb spec/gruf_config_converter_spec.rb
```

移行比較ではUnary、server streaming、client streaming、bidiについて、元のGrufの実レスポンスと移行先を照合する。
存在しない商品IDのNotFoundでは、`product_not_found`アプリケーションコードを含む`error-internal-bin`も一致する。
認証なしのリクエストは両方で`UNAUTHENTICATED`となる。
終了時は両プロセスへTERMを送り、成功終了と、所有PIDが`kill(0)`で`ESRCH`になることを確認した。

Core側のケースは追加依存なしで実行し、Interceptorの先読みでリクエストを二重消費しないこと、FIFOの実行順、RPCごとのoptionsの分離も確認する。
標準Controllerと移行済みInterceptorを併用しても読み取り・受信計上は1回で、client streamingの`request.message.call { ... }`とbidiのEnumerableも維持する。
遅延ストリームが最初の応答後に失敗した場合、列挙中もInterceptorとMiddlewareが有効で、終了処理・NotFoundログ・送信量が反映された。
設定変換はRipperによるリテラル解析だけを使い、実行コード・動的値・未対応項目・重複を拒否する。
入力に置いた`File.write`は実行されず、CLIの既存出力ファイルも変更されなかった。

この記録は移行比較とCoreの対象ケースに限る。リポジトリ全体のカバレッジや、RailsサンプルのPSS評価は別の検証である。
アプリケーションへ移す手順と未対応APIは[Coreの移行ガイド](https://github.com/gritzrpc/gritz-core/blob/main/docs/guides/migrating-from-gruf.md)に記載した。
