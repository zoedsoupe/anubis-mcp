# Changelog

All notable changes to this project are documented in this file.

## [0.13.1](https://github.com/zoedsoupe/anubis-mcp/compare/v1.8.0...v0.13.1) (2026-07-16)


### ⚠ BREAKING CHANGES

* remove client base module and client macro ([#110](https://github.com/zoedsoupe/anubis-mcp/issues/110))
* **phase-3:** server re-implementation and simplification ([#96](https://github.com/zoedsoupe/anubis-mcp/issues/96))

### Features

* `resources/templates/list` method for clients ([a6eb210](https://github.com/zoedsoupe/anubis-mcp/commit/a6eb210af4b6913d8a8480e5247002c2b15f511c))
* add _meta support to Tool struct and JSON encoder ([#108](https://github.com/zoedsoupe/anubis-mcp/issues/108)) ([3b26a1c](https://github.com/zoedsoupe/anubis-mcp/commit/3b26a1c241a3fc5e18b7c1ac3827bd6a7ecaffbd))
* add a serialize_assigns callback for server ([508a8e4](https://github.com/zoedsoupe/anubis-mcp/commit/508a8e4e7295a8995418db58b28c6498a2bc4886)), closes [#199](https://github.com/zoedsoupe/anubis-mcp/issues/199)
* Add Client.await_ready/2 to block until MCP handshake completes ([#117](https://github.com/zoedsoupe/anubis-mcp/issues/117)) ([78a70bc](https://github.com/zoedsoupe/anubis-mcp/commit/78a70bcd13140208c85b0d21905b98ec95e21a7e))
* add independently configurable logs ([#113](https://github.com/zoedsoupe/anubis-mcp/issues/113)) ([bb0be27](https://github.com/zoedsoupe/anubis-mcp/commit/bb0be2716ac41bf43814a16497b209fa55cc811b))
* add instructions field to initialize response ([#122](https://github.com/zoedsoupe/anubis-mcp/issues/122)) ([d0d6816](https://github.com/zoedsoupe/anubis-mcp/commit/d0d68168094fec7d154ddd99cc1c68d766b6f8d2))
* add internal client/transport state inspect on cli/mix tasks ([#61](https://github.com/zoedsoupe/anubis-mcp/issues/61)) ([83550ee](https://github.com/zoedsoupe/anubis-mcp/commit/83550ee40a16da5b2221780cfa926fa827f33d17))
* add OAuth 2.1 authorization for MCP servers ([#158](https://github.com/zoedsoupe/anubis-mcp/issues/158)) ([64d4083](https://github.com/zoedsoupe/anubis-mcp/commit/64d40831a3191827096a5b8f6f7f71a9ae4c916f))
* add Registry.PG for distributed session tracking via :pg ([#160](https://github.com/zoedsoupe/anubis-mcp/issues/160)) ([a757f59](https://github.com/zoedsoupe/anubis-mcp/commit/a757f594db918af062eb4eff5b591379736a342f))
* add resource subscription capability implementation ([#152](https://github.com/zoedsoupe/anubis-mcp/issues/152)) ([4a6ce40](https://github.com/zoedsoupe/anubis-mcp/commit/4a6ce40f11e170c84f51fecdb354d531792287ed))
* add timeout for client/server -&gt; transport calling option ([#50](https://github.com/zoedsoupe/anubis-mcp/issues/50)) ([1e37c23](https://github.com/zoedsoupe/anubis-mcp/commit/1e37c23d3af3f40c54e0ba8b1bcc5043d80547d1))
* allow customize server registry impl ([#94](https://github.com/zoedsoupe/anubis-mcp/issues/94)) ([f3ac087](https://github.com/zoedsoupe/anubis-mcp/commit/f3ac08749a7c361466a7a619f9782e8d8706a7b6))
* allow json schema fields on tools/prompts definition ([#99](https://github.com/zoedsoupe/anubis-mcp/issues/99)) ([0345f12](https://github.com/zoedsoupe/anubis-mcp/commit/0345f122484a0169645c5da07e50c2d64fd6c5f5))
* allow multiple client &lt;&gt; transport pairs ([#24](https://github.com/zoedsoupe/anubis-mcp/issues/24)) ([933876d](https://github.com/zoedsoupe/anubis-mcp/commit/933876d2fe01b64eb1f086f0afcf90e8043e6473))
* allow redact patterns on server assigns/data ([#190](https://github.com/zoedsoupe/anubis-mcp/issues/190)) ([07af99f](https://github.com/zoedsoupe/anubis-mcp/commit/07af99f9e43d2afa87bf5504437ecf21c346a1d7))
* allow sse graceful shutdown and handle sse streaming reconnection ([#25](https://github.com/zoedsoupe/anubis-mcp/issues/25)) ([008725d](https://github.com/zoedsoupe/anubis-mcp/commit/008725d604111d59954d583df4dae98b622779d7))
* allow template resources registration ([#43](https://github.com/zoedsoupe/anubis-mcp/issues/43)) ([9af9b8d](https://github.com/zoedsoupe/anubis-mcp/commit/9af9b8dcf4368ba981b667acc86b47b45a7d8ff4))
* basic client interface API ([fd3412d](https://github.com/zoedsoupe/anubis-mcp/commit/fd3412da180d217f955496a467edabbffd874dce))
* batch operations on server-side ([#125](https://github.com/zoedsoupe/anubis-mcp/issues/125)) ([28eea7c](https://github.com/zoedsoupe/anubis-mcp/commit/28eea7cd15f72c4effccc8475e6b301b2cd9745c))
* better dsl for embedded nested fields on server components ([#199](https://github.com/zoedsoupe/anubis-mcp/issues/199)) ([097f5fd](https://github.com/zoedsoupe/anubis-mcp/commit/097f5fd8f788aaaa73c5e3d6699937656488886f))
* centralized state management ([#31](https://github.com/zoedsoupe/anubis-mcp/issues/31)) ([76c0ab1](https://github.com/zoedsoupe/anubis-mcp/commit/76c0ab1451219712fb595ebd8f86f9806e30f725))
* client request cancelation ([#35](https://github.com/zoedsoupe/anubis-mcp/issues/35)) ([ace2c3b](https://github.com/zoedsoupe/anubis-mcp/commit/ace2c3b356ba376222e3315ca86ca3b43dee9ef2))
* client sampling capability ([#170](https://github.com/zoedsoupe/anubis-mcp/issues/170)) ([da617a6](https://github.com/zoedsoupe/anubis-mcp/commit/da617a694dbeff1d363e7b671a31f484e202e685))
* client support new mcp spec ([#83](https://github.com/zoedsoupe/anubis-mcp/issues/83)) ([73d14f7](https://github.com/zoedsoupe/anubis-mcp/commit/73d14f77522cef0f7212230c05cdac23ee2d93e2))
* create client operation struct ([#56](https://github.com/zoedsoupe/anubis-mcp/issues/56)) ([083bda6](https://github.com/zoedsoupe/anubis-mcp/commit/083bda6d61922b9a840047836f4f740436a9fdd8))
* dispatch session requests in supervised tasks ([#153](https://github.com/zoedsoupe/anubis-mcp/issues/153)) ([c39f405](https://github.com/zoedsoupe/anubis-mcp/commit/c39f40528c45d00d47e61511205c429155df3602))
* drop Application callback + CLI, make Finch pool injectable ([#224](https://github.com/zoedsoupe/anubis-mcp/issues/224)) ([34167a9](https://github.com/zoedsoupe/anubis-mcp/commit/34167a95c9eb7802f8dfdd7fc95892b9e724d2e0))
* **elicitation:** MCP 2025-06-18 elicitation support ([#139](https://github.com/zoedsoupe/anubis-mcp/issues/139)) ([9a65129](https://github.com/zoedsoupe/anubis-mcp/commit/9a65129caad4e3a2cdd11a4ad832b644a686d44a))
* enable log disabling ([#78](https://github.com/zoedsoupe/anubis-mcp/issues/78)) ([fa1453f](https://github.com/zoedsoupe/anubis-mcp/commit/fa1453fee9b015c0ad7f9ac223749a9c9f1fcf6a))
* extensive guides and documentation ([b39ccca](https://github.com/zoedsoupe/anubis-mcp/commit/b39ccca264d5230bd10f1526784d2c1b6672bedc))
* http/sse transport ([#7](https://github.com/zoedsoupe/anubis-mcp/issues/7)) ([690a57f](https://github.com/zoedsoupe/anubis-mcp/commit/690a57fb18d641b42cab9ba2c752023b3ddc9a47))
* implement termination cleanup on Hermes.Client ([#43](https://github.com/zoedsoupe/anubis-mcp/issues/43)) ([d7bbf5d](https://github.com/zoedsoupe/anubis-mcp/commit/d7bbf5df545554e34a0545f1e3c8f90c12002708))
* improve cli experience with help cmd and sse conn info ([#37](https://github.com/zoedsoupe/anubis-mcp/issues/37)) ([0122af2](https://github.com/zoedsoupe/anubis-mcp/commit/0122af286f91ab039f0bcd1f3391e17d4489f8e4))
* improve cli experience with help cmd and sse conn info ([#37](https://github.com/zoedsoupe/anubis-mcp/issues/37)) ([7a9d4e7](https://github.com/zoedsoupe/anubis-mcp/commit/7a9d4e7a4274bba355a7a90e94f8bd205f2eaf90))
* improve interactive mix tasks for testing mcp servers ([#34](https://github.com/zoedsoupe/anubis-mcp/issues/34)) ([53779a9](https://github.com/zoedsoupe/anubis-mcp/commit/53779a9da578413d5e07162c0082dfbe98c20ee8))
* improve log handling on core lib and interactive/cli ([#68](https://github.com/zoedsoupe/anubis-mcp/issues/68)) ([7717f37](https://github.com/zoedsoupe/anubis-mcp/commit/7717f373074fde9e4d6ee92f975207508e13ecbf))
* improve sse uri path handling ([#36](https://github.com/zoedsoupe/anubis-mcp/issues/36)) ([7ed2ea8](https://github.com/zoedsoupe/anubis-mcp/commit/7ed2ea86e839e913832c2603ecc238c4fbd91390))
* improve sse uri path handling ([#36](https://github.com/zoedsoupe/anubis-mcp/issues/36)) ([f044d7d](https://github.com/zoedsoupe/anubis-mcp/commit/f044d7d314f610ecfa14a67c39c61bb57fc2d74e))
* inject user and transport data on mcp server frame ([#106](https://github.com/zoedsoupe/anubis-mcp/issues/106)) ([feb2ce3](https://github.com/zoedsoupe/anubis-mcp/commit/feb2ce308e9fd0cde4118b294dd47ce64d8db18f))
* legacy sse server transport ([#102](https://github.com/zoedsoupe/anubis-mcp/issues/102)) ([4a71088](https://github.com/zoedsoupe/anubis-mcp/commit/4a71088713071a726bde03bf1385c3c794d2134b))
* low level genservy mcp server implementation (stdio + stremable http) ([#77](https://github.com/zoedsoupe/anubis-mcp/issues/77)) ([e6606b4](https://github.com/zoedsoupe/anubis-mcp/commit/e6606b4d66a2d7ddeb6c32e0041c22d4f0036ac5))
* mcp domain model ([#28](https://github.com/zoedsoupe/anubis-mcp/issues/28)) ([f8c877b](https://github.com/zoedsoupe/anubis-mcp/commit/f8c877bd33cc29dce7fecdf1a7843ded0d810568))
* mcp high level server components definition ([#91](https://github.com/zoedsoupe/anubis-mcp/issues/91)) ([007f41d](https://github.com/zoedsoupe/anubis-mcp/commit/007f41d33874fd9f1b5e340ecbe16317dc3576b7))
* mcp server handlers refactored ([#92](https://github.com/zoedsoupe/anubis-mcp/issues/92)) ([e213e04](https://github.com/zoedsoupe/anubis-mcp/commit/e213e046b1360b24ff9e42835cdf80f5fe2ae4fa))
* MCP Tasks (2025-11-25) — server-receiver for tools/call ([#98](https://github.com/zoedsoupe/anubis-mcp/issues/98)) ([#155](https://github.com/zoedsoupe/anubis-mcp/issues/155)) ([a1c5cfc](https://github.com/zoedsoupe/anubis-mcp/commit/a1c5cfc0ec6da9a9e7fba07dc1efc98096ea856c))
* missing notifications handlers ([#129](https://github.com/zoedsoupe/anubis-mcp/issues/129)) ([34d5934](https://github.com/zoedsoupe/anubis-mcp/commit/34d593499fdd846f430b93b4c52ca986f345646d))
* mvp higher level mcp server definition ([#84](https://github.com/zoedsoupe/anubis-mcp/issues/84)) ([a5fec1c](https://github.com/zoedsoupe/anubis-mcp/commit/a5fec1c976595c3363d4eec83e0cbc382eac9207))
* new server response contents for tools/resources with annotations (2025-06-18) ([#195](https://github.com/zoedsoupe/anubis-mcp/issues/195)) ([9b65308](https://github.com/zoedsoupe/anubis-mcp/commit/9b653087a6ddfac399b33be2c4be54d564335c84))
* pluggable session supervisor and :via tuple session naming ([#133](https://github.com/zoedsoupe/anubis-mcp/issues/133)) ([d060f56](https://github.com/zoedsoupe/anubis-mcp/commit/d060f5650cb3255489fa24eb12d4f3c0a839f10f))
* pretty print tool arguments on list_tools ([#57](https://github.com/zoedsoupe/anubis-mcp/issues/57)) ([03f8781](https://github.com/zoedsoupe/anubis-mcp/commit/03f87813955754fd1c748b3002f1a9227d706e57))
* progress notifications ([#26](https://github.com/zoedsoupe/anubis-mcp/issues/26)) ([a3245a0](https://github.com/zoedsoupe/anubis-mcp/commit/a3245a08bb63669059d483b3179744ede3b43714))
* redis based session store (continue from [#48](https://github.com/zoedsoupe/anubis-mcp/issues/48)) ([#55](https://github.com/zoedsoupe/anubis-mcp/issues/55)) ([fddea32](https://github.com/zoedsoupe/anubis-mcp/commit/fddea327ef8d91c57c4dc65f527aadc3e8d105a2))
* **redis:** add redix_opts for SSL/TLS support ([#59](https://github.com/zoedsoupe/anubis-mcp/issues/59)) ([3fd674a](https://github.com/zoedsoupe/anubis-mcp/commit/3fd674a6c35b69896907d339f83d85eb5ea37041))
* resource templates with RFC 6570 URI matching ([#141](https://github.com/zoedsoupe/anubis-mcp/issues/141)) ([ef66844](https://github.com/zoedsoupe/anubis-mcp/commit/ef668449d79260e20d026752f496e8e4b919e3b1))
* resources templates ([#193](https://github.com/zoedsoupe/anubis-mcp/issues/193)) ([1457e59](https://github.com/zoedsoupe/anubis-mcp/commit/1457e59f16b77ca894b07a731d69ca5f8337c42b))
* roadmap and protocol update proposal ([#53](https://github.com/zoedsoupe/anubis-mcp/issues/53)) ([52cbf10](https://github.com/zoedsoupe/anubis-mcp/commit/52cbf10b5215e20554c5b4811324e13356580605))
* roots/list and completion features ([#178](https://github.com/zoedsoupe/anubis-mcp/issues/178)) ([d22a6bd](https://github.com/zoedsoupe/anubis-mcp/commit/d22a6bdfb92189e54455c49120abc2c7fa4f8814))
* rpc and mcp specific message parsing ([#5](https://github.com/zoedsoupe/anubis-mcp/issues/5)) ([531b416](https://github.com/zoedsoupe/anubis-mcp/commit/531b4160cb3cf4cef4647252b0d0ebf8a56e75a6))
* runtime server components, simplified api ([#153](https://github.com/zoedsoupe/anubis-mcp/issues/153)) ([8af35d6](https://github.com/zoedsoupe/anubis-mcp/commit/8af35d67cd15d125e40ab9b115ff6900c3487ea5))
* server components cursor pagination ([#177](https://github.com/zoedsoupe/anubis-mcp/issues/177)) ([a95eba7](https://github.com/zoedsoupe/anubis-mcp/commit/a95eba7cc2ffcefca99b3961b80094bb12a3912f))
* server-side sampling capability ([#173](https://github.com/zoedsoupe/anubis-mcp/issues/173)) ([c09e7f3](https://github.com/zoedsoupe/anubis-mcp/commit/c09e7f3a5e95e59f5644ef12e1602b3b8621df7f))
* **sse:** support custom base and sse paths for client ([#19](https://github.com/zoedsoupe/anubis-mcp/issues/19)) ([787bc2d](https://github.com/zoedsoupe/anubis-mcp/commit/787bc2d0092948100df5830e2d451e56ef1126ed))
* **sse:** unit tests... ([#20](https://github.com/zoedsoupe/anubis-mcp/issues/20)) ([4941fd4](https://github.com/zoedsoupe/anubis-mcp/commit/4941fd4c5602364e29ea85fad47a2636f6d1ab0c))
* standard error resposne ([#32](https://github.com/zoedsoupe/anubis-mcp/issues/32)) ([52602dd](https://github.com/zoedsoupe/anubis-mcp/commit/52602ddeb9fe6951c3003212bad51b49a03b346a))
* stateful client interface ([#6](https://github.com/zoedsoupe/anubis-mcp/issues/6)) ([6b97987](https://github.com/zoedsoupe/anubis-mcp/commit/6b979878f764941508a0ef3ee47c62516bc24c3e))
* **streamable_http:** per-subscriber metadata and targeted sends ([#218](https://github.com/zoedsoupe/anubis-mcp/issues/218)) ([d6cf7b1](https://github.com/zoedsoupe/anubis-mcp/commit/d6cf7b1528949be6fb8971e68005f1d7bfa1b0e9))
* structured server-client logging support ([#27](https://github.com/zoedsoupe/anubis-mcp/issues/27)) ([4e1dfa7](https://github.com/zoedsoupe/anubis-mcp/commit/4e1dfa7c275d13c7068cd0c03cea7ebdd7f756cd))
* support batch operations on client side ([#101](https://github.com/zoedsoupe/anubis-mcp/issues/101)) ([fadf28d](https://github.com/zoedsoupe/anubis-mcp/commit/fadf28d80068f3f1e77835fd46a276338048f0bc))
* telemetry ([#54](https://github.com/zoedsoupe/anubis-mcp/issues/54)) ([c52734e](https://github.com/zoedsoupe/anubis-mcp/commit/c52734eef4e9e813dc5799c9fdd4488fe84cf18f))
* tools annotations ([#127](https://github.com/zoedsoupe/anubis-mcp/issues/127)) ([c83e8f1](https://github.com/zoedsoupe/anubis-mcp/commit/c83e8f1b0e721b1a03960ac67cdd0774337675dc))
* tools output schema feature (2025-06-18) ([#194](https://github.com/zoedsoupe/anubis-mcp/issues/194)) ([8088a49](https://github.com/zoedsoupe/anubis-mcp/commit/8088a49ce4463a01e899418bb9c34fce30427d3c))
* websocket transport ([#70](https://github.com/zoedsoupe/anubis-mcp/issues/70)) ([cee3945](https://github.com/zoedsoupe/anubis-mcp/commit/cee3945ab0cfd1ee94a5ea8a04b85a11f78f1510))


### Bug Fixes

* added server component description/0 callback ([#58](https://github.com/zoedsoupe/anubis-mcp/issues/58)) ([a094473](https://github.com/zoedsoupe/anubis-mcp/commit/a094473916f7ac414369bb2faab1593fd141a7f1))
* align docs and parsing of server component schema-field definition options ([#12](https://github.com/zoedsoupe/anubis-mcp/issues/12)) ([cb2df76](https://github.com/zoedsoupe/anubis-mcp/commit/cb2df761e05beacf2beb3d5e94bf56329c203cc7))
* allow configuring server request timeout ([#182](https://github.com/zoedsoupe/anubis-mcp/issues/182)) ([e79fe2f](https://github.com/zoedsoupe/anubis-mcp/commit/e79fe2f003a41517a5ff5e8f6e3fb378bdc43f11))
* allow empty capabilities on incoming JSON-RPC messages ([#105](https://github.com/zoedsoupe/anubis-mcp/issues/105)) ([f0ad4cf](https://github.com/zoedsoupe/anubis-mcp/commit/f0ad4cf1a5a85cc8a56baed875d2d2d200bb5860)), closes [#96](https://github.com/zoedsoupe/anubis-mcp/issues/96)
* allow enum specific type on json-schema ([#121](https://github.com/zoedsoupe/anubis-mcp/issues/121)) ([23c9ce2](https://github.com/zoedsoupe/anubis-mcp/commit/23c9ce2081ed1099ce1f3afbd9318c8a02480039)), closes [#114](https://github.com/zoedsoupe/anubis-mcp/issues/114)
* allow registering a name for the client supervisor ([#117](https://github.com/zoedsoupe/anubis-mcp/issues/117)) ([d356511](https://github.com/zoedsoupe/anubis-mcp/commit/d356511e2fbcf47b6a85ed733671e96d800ac693))
* allow users to control external process messages ([#149](https://github.com/zoedsoupe/anubis-mcp/issues/149)) ([8fef4eb](https://github.com/zoedsoupe/anubis-mcp/commit/8fef4eb753f38a325a1d3a94c310e5fd1c478ede))
* buffer chunked STDIO responses before decoding in client ([#127](https://github.com/zoedsoupe/anubis-mcp/issues/127)) ([21d567b](https://github.com/zoedsoupe/anubis-mcp/commit/21d567bdd846acccf61e6166f837a4393e3285ae))
* Check Process.alive? before sending to SSE handler ([#82](https://github.com/zoedsoupe/anubis-mcp/issues/82)) ([6887fe4](https://github.com/zoedsoupe/anubis-mcp/commit/6887fe48464e167f5ebb813a2f8e09b3194a9988))
* client reinitialization from interactive cli ([#55](https://github.com/zoedsoupe/anubis-mcp/issues/55)) ([cb6b167](https://github.com/zoedsoupe/anubis-mcp/commit/cb6b16708aa95f6bae244c9f0a13b7558079bdc5))
* client should send both sse/json headers on POST requests ([#134](https://github.com/zoedsoupe/anubis-mcp/issues/134)) ([e906b7f](https://github.com/zoedsoupe/anubis-mcp/commit/e906b7f02bf390faecc2b6bd39aab05ef9c500b1))
* correct arguments in Logging.should_log? ([#47](https://github.com/zoedsoupe/anubis-mcp/issues/47)) ([6f550e6](https://github.com/zoedsoupe/anubis-mcp/commit/6f550e647fd5e6e7c6cdfb233e1cc8a4ac530fc7))
* correct capability parsing to nest options under capability keys ([#31](https://github.com/zoedsoupe/anubis-mcp/issues/31)) ([9946027](https://github.com/zoedsoupe/anubis-mcp/commit/9946027072aee81297ee3c6c10e75acbb1328ae3))
* correct SSE task lifecycle bugs in StreamableHTTP transport ([#130](https://github.com/zoedsoupe/anubis-mcp/issues/130)) ([d255059](https://github.com/zoedsoupe/anubis-mcp/commit/d2550591db017322ee608bc2fe1b97c4db0f37ca))
* correctly allows macro-based/callback-based server implementations ([#131](https://github.com/zoedsoupe/anubis-mcp/issues/131)) ([d7bfc75](https://github.com/zoedsoupe/anubis-mcp/commit/d7bfc7541a8c381573f1a20ebc37d4a7dbaaa139))
* correctly append 2025-11-25 version to http transport ([711027b](https://github.com/zoedsoupe/anubis-mcp/commit/711027b6cbe5f0db006384d953588ec01390b619)), closes [#220](https://github.com/zoedsoupe/anubis-mcp/issues/220)
* correctly encode prompt/resource ([#155](https://github.com/zoedsoupe/anubis-mcp/issues/155)) ([4249b13](https://github.com/zoedsoupe/anubis-mcp/commit/4249b137e43587862de2e59acba4660ac785702a))
* correctly escape quoted expressions ([#119](https://github.com/zoedsoupe/anubis-mcp/issues/119)) ([0c469c5](https://github.com/zoedsoupe/anubis-mcp/commit/0c469c552d8d5fd2498706b4b1f41100e8561e2f)), closes [#118](https://github.com/zoedsoupe/anubis-mcp/issues/118)
* correctly handle mcp requests on phoenix apps ([#88](https://github.com/zoedsoupe/anubis-mcp/issues/88)) ([09f4235](https://github.com/zoedsoupe/anubis-mcp/commit/09f42359f0daac694013f0be4f6a74de2be7f4ff)), closes [#86](https://github.com/zoedsoupe/anubis-mcp/issues/86)
* correctly handle timeouts and keepalive ([#41](https://github.com/zoedsoupe/anubis-mcp/issues/41)) ([2f44840](https://github.com/zoedsoupe/anubis-mcp/commit/2f448404601799a061c9971bee69222d9c7bf927))
* correctly parse dates when default values are passed ([58f6368](https://github.com/zoedsoupe/anubis-mcp/commit/58f63686574e230269f847ee793d9561976653bb))
* correctly parse peri numeric contrainsts to json-schema ([#160](https://github.com/zoedsoupe/anubis-mcp/issues/160)) ([808c2c0](https://github.com/zoedsoupe/anubis-mcp/commit/808c2c09e490bf9a866d5575abbf08d355c8324b))
* correctly pass server call timeout options ([a49f497](https://github.com/zoedsoupe/anubis-mcp/commit/a49f4973545860e98fa056655ff229df70c70749))
* correctly set supported versions for different transports ([#205](https://github.com/zoedsoupe/anubis-mcp/issues/205)) ([30435e1](https://github.com/zoedsoupe/anubis-mcp/commit/30435e1e76aeab99b30d9cbaf0ad6f7f155e85d9))
* correctly truncate tools args ([2492cda](https://github.com/zoedsoupe/anubis-mcp/commit/2492cda0ae5dccee8f5b3d19afc574c8d5af20c1))
* dedup protocol schema definitions ([ed3e814](https://github.com/zoedsoupe/anubis-mcp/commit/ed3e814d80686b1411f1df1d09edcefb617d04c7)), closes [#157](https://github.com/zoedsoupe/anubis-mcp/issues/157)
* default implementation for server handle_notification ([#135](https://github.com/zoedsoupe/anubis-mcp/issues/135)) ([c958041](https://github.com/zoedsoupe/anubis-mcp/commit/c9580410162c31a62190631f6702024ea3458beb))
* defer streamable_http plug opts fetching to runtime ([#137](https://github.com/zoedsoupe/anubis-mcp/issues/137)) ([9c16141](https://github.com/zoedsoupe/anubis-mcp/commit/9c16141710d18921ee25bd42f4bb09921180300c))
* do not allow duplicate server components and more convenient API ([#180](https://github.com/zoedsoupe/anubis-mcp/issues/180)) ([bc71df8](https://github.com/zoedsoupe/anubis-mcp/commit/bc71df8f7c6fb877f19dada9b17c3eb342d32ccd))
* do not handle domain errors ([#33](https://github.com/zoedsoupe/anubis-mcp/issues/33)) ([20dde00](https://github.com/zoedsoupe/anubis-mcp/commit/20dde0084ab888d17994044a7d8a1a9a9e062dec))
* do not handle domain errors ([#33](https://github.com/zoedsoupe/anubis-mcp/issues/33)) ([c15b260](https://github.com/zoedsoupe/anubis-mcp/commit/c15b260b1b57849fea000a090f76909fc188796a))
* drop compile-connected deps from component/1 macro ([#154](https://github.com/zoedsoupe/anubis-mcp/issues/154)) ([f79949e](https://github.com/zoedsoupe/anubis-mcp/commit/f79949e948adb58d4b033de103fa87c230e5b79d))
* Echo request id in "Server not initialized" error ([#168](https://github.com/zoedsoupe/anubis-mcp/issues/168)) ([113c68f](https://github.com/zoedsoupe/anubis-mcp/commit/113c68fd3ed30b59daa741d0f4e3edc0e5b810cb))
* explicit handle title for components ([#9](https://github.com/zoedsoupe/anubis-mcp/issues/9)) ([1adfed2](https://github.com/zoedsoupe/anubis-mcp/commit/1adfed2f0e18a4cd2dc7d013556455a155a8ff7f))
* fixed erts version to avoid release error ([80780d2](https://github.com/zoedsoupe/anubis-mcp/commit/80780d27caddf30926be777c0e8743b0bc69d28f))
* forward :headers to SSE GET request ([#180](https://github.com/zoedsoupe/anubis-mcp/issues/180)) ([ace4c1a](https://github.com/zoedsoupe/anubis-mcp/commit/ace4c1a1a754733e7df017bbde513f13bd1b5578))
* Forward configured :headers on the DELETE session-teardown request (follow-up to [#180](https://github.com/zoedsoupe/anubis-mcp/issues/180)) ([#213](https://github.com/zoedsoupe/anubis-mcp/issues/213)) ([4edd2c0](https://github.com/zoedsoupe/anubis-mcp/commit/4edd2c03997b66320006079499955a64565a073c))
* handle session expiry gracefully with optional callback and store restore ([#134](https://github.com/zoedsoupe/anubis-mcp/issues/134)) ([3f07717](https://github.com/zoedsoupe/anubis-mcp/commit/3f0771797f60b2b84e2c4909ea3fe33f280a5647))
* handle SSE ping and reconnect events from server ([#65](https://github.com/zoedsoupe/anubis-mcp/issues/65)) ([dccdca3](https://github.com/zoedsoupe/anubis-mcp/commit/dccdca3d650d115afb06b241b0304fce976c3177))
* hermes should respect mix releases startup ([#109](https://github.com/zoedsoupe/anubis-mcp/issues/109)) ([f42d476](https://github.com/zoedsoupe/anubis-mcp/commit/f42d476e1dc05c57479170bd58aaca9028ef1e66))
* include formatter on hex release ([#139](https://github.com/zoedsoupe/anubis-mcp/issues/139)) ([d91b244](https://github.com/zoedsoupe/anubis-mcp/commit/d91b244aeed4211a6653a82705b03da2247db9a3))
* include frame helpers on module-based component ([#163](https://github.com/zoedsoupe/anubis-mcp/issues/163)) ([15ba2c7](https://github.com/zoedsoupe/anubis-mcp/commit/15ba2c7fbdd0a776eabe028aef0350f4f52a43a8))
* interactive http tasks should accept custom headers ([#159](https://github.com/zoedsoupe/anubis-mcp/issues/159)) ([c2fe91e](https://github.com/zoedsoupe/anubis-mcp/commit/c2fe91eff5a701e42a636ee1a291ea51a93f7983))
* log sse_keepalive_failed at :warning, matching sse_send_failed ([#145](https://github.com/zoedsoupe/anubis-mcp/issues/145)) ([1bbd0ce](https://github.com/zoedsoupe/anubis-mcp/commit/1bbd0ce93d4e827518f1aab8e16df69b862c571c))
* loggin should respect the logger config ([#157](https://github.com/zoedsoupe/anubis-mcp/issues/157)) ([0fbf6a6](https://github.com/zoedsoupe/anubis-mcp/commit/0fbf6a652ed9dd5da64716d47ece675192442ea0))
* macros for Elixir 1.20 type checker compatibility ([2086047](https://github.com/zoedsoupe/anubis-mcp/commit/2086047a564b8df2a9e243c6b1fad41f1e8560d4))
* make gun/websocket optional ([#76](https://github.com/zoedsoupe/anubis-mcp/issues/76)) ([8f55057](https://github.com/zoedsoupe/anubis-mcp/commit/8f550571abb42d259c8efa1622624b6304fbec7c))
* more genserver mcp server callbacks, plug based startup and documentation ([#152](https://github.com/zoedsoupe/anubis-mcp/issues/152)) ([9c26b1c](https://github.com/zoedsoupe/anubis-mcp/commit/9c26b1ce4d033e3c69bc872a5ed01a037ec68f59))
* nested timeout ([#71](https://github.com/zoedsoupe/anubis-mcp/issues/71)) ([c7ffa71](https://github.com/zoedsoupe/anubis-mcp/commit/c7ffa71d50a90d376245821f5c8b697f8a6acc1f))
* normalize transport api ([#146](https://github.com/zoedsoupe/anubis-mcp/issues/146)) ([8a30a34](https://github.com/zoedsoupe/anubis-mcp/commit/8a30a34c944ca4d85de622f9063a558bd495c6fc)), closes [#145](https://github.com/zoedsoupe/anubis-mcp/issues/145)
* not crash server on empty tool/prompt args ([#4](https://github.com/zoedsoupe/anubis-mcp/issues/4)) ([ee8043f](https://github.com/zoedsoupe/anubis-mcp/commit/ee8043f331481790931d2d711b6df8f9cd7a4940))
* output schemas should not validate on error resps ([#15](https://github.com/zoedsoupe/anubis-mcp/issues/15)) ([b5faaad](https://github.com/zoedsoupe/anubis-mcp/commit/b5faaad5c409b3616273d5bee822d609ef35803b))
* **phase-5:** remove dead code and update docs ([#104](https://github.com/zoedsoupe/anubis-mcp/issues/104)) ([2a33dfc](https://github.com/zoedsoupe/anubis-mcp/commit/2a33dfcc8435c8612a122c8264ebbc218868dd9a))
* prevent "Server not initialized" race on first request ([#198](https://github.com/zoedsoupe/anubis-mcp/issues/198)) ([6bb60f9](https://github.com/zoedsoupe/anubis-mcp/commit/6bb60f927b282e1648eb74e04366978196329496))
* prevent lost SSE responses when client connection closes ([#132](https://github.com/zoedsoupe/anubis-mcp/issues/132)) ([b7efb4e](https://github.com/zoedsoupe/anubis-mcp/commit/b7efb4e9c0a25795de05f01961077c11e79f530f))
* redix should be loaded ([#71](https://github.com/zoedsoupe/anubis-mcp/issues/71)) ([c352414](https://github.com/zoedsoupe/anubis-mcp/commit/c352414f083ce0ea78273e1813a38a78abc91cd6))
* regression for input/output server schema ([fbf138b](https://github.com/zoedsoupe/anubis-mcp/commit/fbf138b31ccf0352736393293ea2f46c750f40e8))
* remove assign redact feature, simplify server state inspect ([#206](https://github.com/zoedsoupe/anubis-mcp/issues/206)) ([a4d9ae9](https://github.com/zoedsoupe/anubis-mcp/commit/a4d9ae9f0ac5abfb76649271033af75b6ac8afff))
* remove client base module and client macro ([#110](https://github.com/zoedsoupe/anubis-mcp/issues/110)) ([a8ec690](https://github.com/zoedsoupe/anubis-mcp/commit/a8ec690d88a092291934465464712f63140ac923))
* replace opaque KeyError with ArgumentError for missing :client_info ([#135](https://github.com/zoedsoupe/anubis-mcp/issues/135)) ([83bd44a](https://github.com/zoedsoupe/anubis-mcp/commit/83bd44abe51a9361b1d89b8cc44ad047c29e3534))
* scope POST-with-SSE response to originating conn ([#144](https://github.com/zoedsoupe/anubis-mcp/issues/144)) ([ac69060](https://github.com/zoedsoupe/anubis-mcp/commit/ac69060d853c868463c9b7f08bb5f8920d689c74))
* server behaviour with optional callbacks ([#151](https://github.com/zoedsoupe/anubis-mcp/issues/151)) ([91aa191](https://github.com/zoedsoupe/anubis-mcp/commit/91aa1916f28da5972f6b100861a2547697c1ddb7))
* server can now send notifications correctly ([#166](https://github.com/zoedsoupe/anubis-mcp/issues/166)) ([33f32de](https://github.com/zoedsoupe/anubis-mcp/commit/33f32deccd42dc4591832636b2b3fad56ce40661))
* server examples and sse server transport ([f4d3097](https://github.com/zoedsoupe/anubis-mcp/commit/f4d30975e3857084771b820521f8bd205f9321d9))
* server session expiration on idle (configurable) ([#143](https://github.com/zoedsoupe/anubis-mcp/issues/143)) ([d9f7164](https://github.com/zoedsoupe/anubis-mcp/commit/d9f7164028b2b6e8ff3d697f888adf655110bc1f))
* server stdio test againts custom io device ([#136](https://github.com/zoedsoupe/anubis-mcp/issues/136)) ([155b9a1](https://github.com/zoedsoupe/anubis-mcp/commit/155b9a1a4dee129f1b456e5cbd01c11a52009390))
* **server:** resolve session names via Registry to prevent atom-exhaustion DoS ([#188](https://github.com/zoedsoupe/anubis-mcp/issues/188)) ([fdbc238](https://github.com/zoedsoupe/anubis-mcp/commit/fdbc2388298db1ae8026001dcc4d53e34ddbd0cb))
* session serializion errors ([#112](https://github.com/zoedsoupe/anubis-mcp/issues/112)) ([8416cef](https://github.com/zoedsoupe/anubis-mcp/commit/8416cef1e23e22b48fd0c75627c74cab7b22e7c1)), closes [#60](https://github.com/zoedsoupe/anubis-mcp/issues/60)
* **session:** trap_exit so terminate/2 runs on supervisor shutdown ([#209](https://github.com/zoedsoupe/anubis-mcp/issues/209)) ([a224c00](https://github.com/zoedsoupe/anubis-mcp/commit/a224c00f2e5df92cd6b19a561f74ef102c54739d))
* sse endpoint uri merging ([#64](https://github.com/zoedsoupe/anubis-mcp/issues/64)) ([2fa7869](https://github.com/zoedsoupe/anubis-mcp/commit/2fa78698f69d8e4f90e5f56754e71eab4a0dc9c2))
* Start SSE keepalive when first handler is registered ([#83](https://github.com/zoedsoupe/anubis-mcp/issues/83)) ([67d93bb](https://github.com/zoedsoupe/anubis-mcp/commit/67d93bb3ebf79ca477525c07e58d384aa2bf8709))
* stdio server transport working ([#111](https://github.com/zoedsoupe/anubis-mcp/issues/111)) ([b3d42a8](https://github.com/zoedsoupe/anubis-mcp/commit/b3d42a86827e3ef4f4720c5f9cd9ff02e34d62f7))
* **streamable_http:** always advertise both content types on POST ([#178](https://github.com/zoedsoupe/anubis-mcp/issues/178)) ([9c0c6ac](https://github.com/zoedsoupe/anubis-mcp/commit/9c0c6ac085ca3df54222bd835caadaf767cac4c5))
* **streamable_http:** don't close superseded SSE handler to prevent reconnect flap ([#215](https://github.com/zoedsoupe/anubis-mcp/issues/215)) ([e1cc4a8](https://github.com/zoedsoupe/anubis-mcp/commit/e1cc4a8f8b0809f693bb7b9dc34b1ef374c9331b))
* **streamable_http:** emit telemetry on SSE handler registration ([#217](https://github.com/zoedsoupe/anubis-mcp/issues/217)) ([4a4c528](https://github.com/zoedsoupe/anubis-mcp/commit/4a4c5289cb1aeee65cac3345a4f34660fe74207f))
* Timeout options not properly passed to HTTP transport ([#52](https://github.com/zoedsoupe/anubis-mcp/issues/52)) ([0d392d6](https://github.com/zoedsoupe/anubis-mcp/commit/0d392d64010e39f4ce38a4427b960574fa6e82aa))
* use mix.lock as cache key ([#58](https://github.com/zoedsoupe/anubis-mcp/issues/58)) ([6a3134a](https://github.com/zoedsoupe/anubis-mcp/commit/6a3134ae3288d23b333aea7e7467e6ea93a0ba11))


### Reverts

* "Add keep-alive messages to the StreamableHTTP transport ([#11](https://github.com/zoedsoupe/anubis-mcp/issues/11))" ([8ea5a3c](https://github.com/zoedsoupe/anubis-mcp/commit/8ea5a3c8edd31394b4f47cb3e4f73f06d8d12fed))


### Documentation

* correct supervision tree setup ([#118](https://github.com/zoedsoupe/anubis-mcp/issues/118)) ([5c3d406](https://github.com/zoedsoupe/anubis-mcp/commit/5c3d406bab570a4923a35aeb8c64d5a62f789d36))
* revamp and rewrite ([362ab18](https://github.com/zoedsoupe/anubis-mcp/commit/362ab18bfd05333938f6810bd83a9729ba599c7d))
* rewrite introduction/home documentation page ([34baf39](https://github.com/zoedsoupe/anubis-mcp/commit/34baf3907e7e50b490398f48c32a782d213c36e9))


### Miscellaneous Chores

* add llms summary about the library ([#175](https://github.com/zoedsoupe/anubis-mcp/issues/175)) ([ed0e608](https://github.com/zoedsoupe/anubis-mcp/commit/ed0e60872e5b77ddb6ffff13da6c1e20b1c2d7a2))
* add sponsors section with coderabbit ([f04f8bb](https://github.com/zoedsoupe/anubis-mcp/commit/f04f8bb100eb03602fd59716936ce2353040f4b2))
* allow different kind of components have the same name ([#181](https://github.com/zoedsoupe/anubis-mcp/issues/181)) ([d5ba6f5](https://github.com/zoedsoupe/anubis-mcp/commit/d5ba6f56fb54ed07e46d37c2217dcf76c793762f))
* capture log from stdio transports processes ([9588b67](https://github.com/zoedsoupe/anubis-mcp/commit/9588b673e116edf890a49b6cbd90bfbb96791c38))
* change setup-zig version on ci ([a6be38f](https://github.com/zoedsoupe/anubis-mcp/commit/a6be38f3a520e4c6d86199faf4e185a1871d37c4))
* deprecate sse transport ([#187](https://github.com/zoedsoupe/anubis-mcp/issues/187)) ([1932fbc](https://github.com/zoedsoupe/anubis-mcp/commit/1932fbcdef12194c496d3ac074b17ef65fe18e49))
* **deps:** bump the npm_and_yarn group across 1 directory with 2 updates ([#198](https://github.com/zoedsoupe/anubis-mcp/issues/198)) ([5e21aac](https://github.com/zoedsoupe/anubis-mcp/commit/5e21aac07ab1e709cb2bad8ddf9f45ba3ff99ef9))
* encapsulate transport_parse_state into the Client.State struct ([76a253a](https://github.com/zoedsoupe/anubis-mcp/commit/76a253a78d172ca2c5caee76094e280e3de20d9b))
* move example apps to dedicated root folder ([8731c10](https://github.com/zoedsoupe/anubis-mcp/commit/8731c1071f9e46f03ac4a0ba2b36b8f6725497c1))
* old release are from the original fork ([e99d8ba](https://github.com/zoedsoupe/anubis-mcp/commit/e99d8baa7e8c00f3105ce16f8ac2178698859278))
* plug router config on readme ([#2](https://github.com/zoedsoupe/anubis-mcp/issues/2)) ([243176c](https://github.com/zoedsoupe/anubis-mcp/commit/243176cd95fdb3ac0a500630b4e80cc26bc33769))
* readme ([bed6ff7](https://github.com/zoedsoupe/anubis-mcp/commit/bed6ff78ed617af3eaba6d316c1107643e8aea06))
* release 0.10.0 ([#124](https://github.com/zoedsoupe/anubis-mcp/issues/124)) ([8db7a92](https://github.com/zoedsoupe/anubis-mcp/commit/8db7a927115d7071dc4e8425d89d78d357f6253e))
* release 0.10.1 ([#133](https://github.com/zoedsoupe/anubis-mcp/issues/133)) ([2caf67b](https://github.com/zoedsoupe/anubis-mcp/commit/2caf67bb222c27a993e44aa1609ca19754c0e260))
* release 0.10.2 ([#136](https://github.com/zoedsoupe/anubis-mcp/issues/136)) ([580d96a](https://github.com/zoedsoupe/anubis-mcp/commit/580d96a68c020a5560a2a631af8b8140f15d1108))
* release 0.10.3 ([#140](https://github.com/zoedsoupe/anubis-mcp/issues/140)) ([2bf9890](https://github.com/zoedsoupe/anubis-mcp/commit/2bf989082fa7e5c37f9ab7bc5a618cff8fe50f7d))
* release 0.10.4 ([#144](https://github.com/zoedsoupe/anubis-mcp/issues/144)) ([ae22d44](https://github.com/zoedsoupe/anubis-mcp/commit/ae22d4416a41bfb7c059a7b7fe6bcbc1c8cc6256))
* release 0.10.5 ([#147](https://github.com/zoedsoupe/anubis-mcp/issues/147)) ([fe8f374](https://github.com/zoedsoupe/anubis-mcp/commit/fe8f374d9687aa0d37e132c323841f9f37ae8773))
* release 0.11.0 ([#150](https://github.com/zoedsoupe/anubis-mcp/issues/150)) ([615e9ac](https://github.com/zoedsoupe/anubis-mcp/commit/615e9ac3a43e929bcc8ab4f25fbc276051e3eb52))
* release 0.11.1 ([#158](https://github.com/zoedsoupe/anubis-mcp/issues/158)) ([e0c63f4](https://github.com/zoedsoupe/anubis-mcp/commit/e0c63f4e0fc2dd8a1521720937376ade0ddf2700))
* release 0.11.2 ([#161](https://github.com/zoedsoupe/anubis-mcp/issues/161)) ([2520588](https://github.com/zoedsoupe/anubis-mcp/commit/2520588283e657a64b7e49a56e41a0c91fe40a13))
* release 0.11.3 ([#167](https://github.com/zoedsoupe/anubis-mcp/issues/167)) ([1ff0786](https://github.com/zoedsoupe/anubis-mcp/commit/1ff078657fcd0bce3dd7522bb922da57eb46a51c))
* release 0.12.0 ([#171](https://github.com/zoedsoupe/anubis-mcp/issues/171)) ([c378929](https://github.com/zoedsoupe/anubis-mcp/commit/c378929288ac86df540795c01ed64fb1f3766c2c))
* release 0.12.1 ([#184](https://github.com/zoedsoupe/anubis-mcp/issues/184)) ([9f5f751](https://github.com/zoedsoupe/anubis-mcp/commit/9f5f75150529a1d3534df73bc85211a49ef11f08))
* release 0.13.0 ([#191](https://github.com/zoedsoupe/anubis-mcp/issues/191)) ([cfaaa9d](https://github.com/zoedsoupe/anubis-mcp/commit/cfaaa9dd6ee3fbddad4a3c9f20d5328a1a916c75))
* release 0.13.1 ([#3](https://github.com/zoedsoupe/anubis-mcp/issues/3)) ([d29be6e](https://github.com/zoedsoupe/anubis-mcp/commit/d29be6e0bb57bfa8793ba299217bd34f1f242dc6))
* release 0.14.0 ([#6](https://github.com/zoedsoupe/anubis-mcp/issues/6)) ([c643b8a](https://github.com/zoedsoupe/anubis-mcp/commit/c643b8a66a1416fd4dc15aed353c1cef5676e379))
* release 0.14.1 ([#23](https://github.com/zoedsoupe/anubis-mcp/issues/23)) ([9c259da](https://github.com/zoedsoupe/anubis-mcp/commit/9c259da0762bf0f47ae0ddb6f91242d59be161f9))
* release 0.15.0 ([#49](https://github.com/zoedsoupe/anubis-mcp/issues/49)) ([eafc990](https://github.com/zoedsoupe/anubis-mcp/commit/eafc9909f05bb13d7b5e0b04b3f62dba95bec848))
* release 0.16.0 ([#57](https://github.com/zoedsoupe/anubis-mcp/issues/57)) ([9fd2eda](https://github.com/zoedsoupe/anubis-mcp/commit/9fd2eda662399343029e4fb84d96edbe74eecde0))
* release 0.17.0 ([#61](https://github.com/zoedsoupe/anubis-mcp/issues/61)) ([7a6926c](https://github.com/zoedsoupe/anubis-mcp/commit/7a6926cf43c472146e0984e49ace152914323ea8))
* release 0.17.1 ([#94](https://github.com/zoedsoupe/anubis-mcp/issues/94)) ([5ab1248](https://github.com/zoedsoupe/anubis-mcp/commit/5ab124838bf9971b13b39b5ebe98557e64555db5))
* release 0.5.0 ([#80](https://github.com/zoedsoupe/anubis-mcp/issues/80)) ([feac95b](https://github.com/zoedsoupe/anubis-mcp/commit/feac95bfafe01b35846b65ecda8553820ed8d6a3))
* release 0.6.0 ([#89](https://github.com/zoedsoupe/anubis-mcp/issues/89)) ([5f44c37](https://github.com/zoedsoupe/anubis-mcp/commit/5f44c371dc7d18604c88d5bab88890a6e30a1248))
* release 0.7.0 ([#100](https://github.com/zoedsoupe/anubis-mcp/issues/100)) ([c9efd80](https://github.com/zoedsoupe/anubis-mcp/commit/c9efd80614f04a76d1d564435a659cb50f7ed0d1))
* release 0.8.0 ([#104](https://github.com/zoedsoupe/anubis-mcp/issues/104)) ([cc535dd](https://github.com/zoedsoupe/anubis-mcp/commit/cc535ddefed63b539561ac7fb1a18c4d71e8e9b0))
* release 0.8.1 ([#110](https://github.com/zoedsoupe/anubis-mcp/issues/110)) ([9fca055](https://github.com/zoedsoupe/anubis-mcp/commit/9fca055e38187aa3aaeaed2084c57d41d63936c2))
* release 0.8.2 ([#112](https://github.com/zoedsoupe/anubis-mcp/issues/112)) ([5dc7d40](https://github.com/zoedsoupe/anubis-mcp/commit/5dc7d405c0568da8cfa1665e8337b6ae9b007284))
* release 0.9.0 ([#116](https://github.com/zoedsoupe/anubis-mcp/issues/116)) ([73ac1ed](https://github.com/zoedsoupe/anubis-mcp/commit/73ac1ed6fc15ae514e5da142bda93a0ee858f1eb))
* release 0.9.1 ([#120](https://github.com/zoedsoupe/anubis-mcp/issues/120)) ([a490789](https://github.com/zoedsoupe/anubis-mcp/commit/a490789ad68b504a114505677674087169ea4137))
* release 1.0.0 ([#97](https://github.com/zoedsoupe/anubis-mcp/issues/97)) ([aa0d583](https://github.com/zoedsoupe/anubis-mcp/commit/aa0d583fac97d0a1588f5b19ca5d94cdba8ea142))
* release 1.1.0 ([#119](https://github.com/zoedsoupe/anubis-mcp/issues/119)) ([79748da](https://github.com/zoedsoupe/anubis-mcp/commit/79748da51e89f3278cedf136b6454c91eac793f9))
* release 1.1.1 ([#129](https://github.com/zoedsoupe/anubis-mcp/issues/129)) ([3364d77](https://github.com/zoedsoupe/anubis-mcp/commit/3364d7740278ecd3d1611631be97291c053e1cc0))
* release 1.2.0 ([#131](https://github.com/zoedsoupe/anubis-mcp/issues/131)) ([6ace476](https://github.com/zoedsoupe/anubis-mcp/commit/6ace47607799ef9b105193f3cb39c213f51cbe6a))
* release 1.3.0 ([#140](https://github.com/zoedsoupe/anubis-mcp/issues/140)) ([d932d2b](https://github.com/zoedsoupe/anubis-mcp/commit/d932d2ba465ee5943fda69569d903820f7a22528))
* release 1.3.1 ([#147](https://github.com/zoedsoupe/anubis-mcp/issues/147)) ([dca7123](https://github.com/zoedsoupe/anubis-mcp/commit/dca7123fae73a5078dd38637a457b097757c928a))
* release 1.4.0 ([#150](https://github.com/zoedsoupe/anubis-mcp/issues/150)) ([727c271](https://github.com/zoedsoupe/anubis-mcp/commit/727c27107f37d63252ae730189c4709acdf195d0))
* release 1.5.0 ([#156](https://github.com/zoedsoupe/anubis-mcp/issues/156)) ([b637ada](https://github.com/zoedsoupe/anubis-mcp/commit/b637adaeee5326873c9da6502eb894b9767cc4d4))
* release 1.6.0 ([#162](https://github.com/zoedsoupe/anubis-mcp/issues/162)) ([ba20e56](https://github.com/zoedsoupe/anubis-mcp/commit/ba20e5608b3064199671afec4f0cf11f9c031701))
* release 1.6.1 ([#169](https://github.com/zoedsoupe/anubis-mcp/issues/169)) ([b0c0272](https://github.com/zoedsoupe/anubis-mcp/commit/b0c02722f076506affb6bde794e07a87de8f32bf))
* release 1.6.2 ([#184](https://github.com/zoedsoupe/anubis-mcp/issues/184)) ([ec6ab05](https://github.com/zoedsoupe/anubis-mcp/commit/ec6ab05b63dbd28136a18fa6f8a7640775d48a46))
* release 1.7.0 ([#186](https://github.com/zoedsoupe/anubis-mcp/issues/186)) ([17d742f](https://github.com/zoedsoupe/anubis-mcp/commit/17d742f51c511b130483b0404630e42c667c905e))
* release 1.8.0 ([#223](https://github.com/zoedsoupe/anubis-mcp/issues/223)) ([9f1a9fa](https://github.com/zoedsoupe/anubis-mcp/commit/9f1a9fa2607deac40338601557fb357e8becfe72))
* release please correct version on readme ([#128](https://github.com/zoedsoupe/anubis-mcp/issues/128)) ([d0125c6](https://github.com/zoedsoupe/anubis-mcp/commit/d0125c664b5190b560bb988ff01d17cbdba814bd))
* release please should include all files ([#108](https://github.com/zoedsoupe/anubis-mcp/issues/108)) ([d0a25b9](https://github.com/zoedsoupe/anubis-mcp/commit/d0a25b968c83ae1023ffffc8ee07b5b490122c03))
* remove dead llms.txt ([ba555d8](https://github.com/zoedsoupe/anubis-mcp/commit/ba555d842827ebf0be86b20822739af1d2f6a346))
* rename hermes folders/files to anubis ([#5](https://github.com/zoedsoupe/anubis-mcp/issues/5)) ([239ee3f](https://github.com/zoedsoupe/anubis-mcp/commit/239ee3f611fd9ba3a8234ee8155da1cb9a8b89c7))
* simplify genserver naming handling, and bidirectional communication client &lt;&gt; transport ([#38](https://github.com/zoedsoupe/anubis-mcp/issues/38)) ([5288ceb](https://github.com/zoedsoupe/anubis-mcp/commit/5288cebaf3aaf211f0f8e5273ef0f365ed3ae31d))
* streamable http on hermes cli (standalone) ([#203](https://github.com/zoedsoupe/anubis-mcp/issues/203)) ([2f41337](https://github.com/zoedsoupe/anubis-mcp/commit/2f41337633c780c902dba5771c4a01ae3a1aabf3))
* suppress SSE deprecation warnings ([bf35754](https://github.com/zoedsoupe/anubis-mcp/commit/bf357549b6774e0a04f1708e49fe394d8646388e))
* supress SSE deprecation warnings ([185058f](https://github.com/zoedsoupe/anubis-mcp/commit/185058f9a2d45a622556ef125bac991e66339aec))
* upcate automatic version ([#98](https://github.com/zoedsoupe/anubis-mcp/issues/98)) ([0c08233](https://github.com/zoedsoupe/anubis-mcp/commit/0c08233371338af24ea66047b4e1a8e9fa5cb055))
* update documentation, simplify, more storytelling ([#168](https://github.com/zoedsoupe/anubis-mcp/issues/168)) ([ccdddc1](https://github.com/zoedsoupe/anubis-mcp/commit/ccdddc1478c09e2f3440a6f1343949aeca854a1d))
* update example projects elixir deps, use fixed otp version and stable version for CLI release ([b362e54](https://github.com/zoedsoupe/anubis-mcp/commit/b362e54594d1551856436eb401a394be33dbf3a6))
* update peri ([#126](https://github.com/zoedsoupe/anubis-mcp/issues/126)) ([7292615](https://github.com/zoedsoupe/anubis-mcp/commit/7292615cf57da0185006df2f6221f8ab93aacd30))


### Code Refactoring

* base mcp server implementation correctly uses streamable http ([#85](https://github.com/zoedsoupe/anubis-mcp/issues/85)) ([29060fd](https://github.com/zoedsoupe/anubis-mcp/commit/29060fd2d2e383c58c727a9085b30162c6b8179a))
* cleaner peri integration ([#137](https://github.com/zoedsoupe/anubis-mcp/issues/137)) ([43226cc](https://github.com/zoedsoupe/anubis-mcp/commit/43226cc9fb2f49edfbf8685fe181eb3093304308)), closes [#123](https://github.com/zoedsoupe/anubis-mcp/issues/123)
* delegate JSON Schema to Peri, retire :mcp_field ([#146](https://github.com/zoedsoupe/anubis-mcp/issues/146)) ([cf0703b](https://github.com/zoedsoupe/anubis-mcp/commit/cf0703bb798443642a29474a8d2fa2e0c522fdbe))
* do not hangle on transport process ([#185](https://github.com/zoedsoupe/anubis-mcp/issues/185)) ([e6ba926](https://github.com/zoedsoupe/anubis-mcp/commit/e6ba9260ceb8e078ca043d6f1ceb41d540b42ca0))
* handle_sampling callback, use frame as entrypoint for notifications ([#176](https://github.com/zoedsoupe/anubis-mcp/issues/176)) ([1e88711](https://github.com/zoedsoupe/anubis-mcp/commit/1e887117ba81751042534d60df79d83a8123a3d9))
* higher-level client implementation ([#111](https://github.com/zoedsoupe/anubis-mcp/issues/111)) ([5de2162](https://github.com/zoedsoupe/anubis-mcp/commit/5de2162b166e390b4dacfd7b9960fab59c81b4d7))
* improve runtime components schema def ([#154](https://github.com/zoedsoupe/anubis-mcp/issues/154)) ([96ff2a9](https://github.com/zoedsoupe/anubis-mcp/commit/96ff2a97be02f0f35ee4a288838a1dbf518bbac3))
* interactive tasks now support JSON file input ([#172](https://github.com/zoedsoupe/anubis-mcp/issues/172)) ([9465266](https://github.com/zoedsoupe/anubis-mcp/commit/946526617171094ccf929a5d9f3bbd8e3a591f18))
* **phase-1:** abstract protocol version negotiation ([#93](https://github.com/zoedsoupe/anubis-mcp/issues/93)) ([f76ee3d](https://github.com/zoedsoupe/anubis-mcp/commit/f76ee3d5d80f8319aa639e264e6df2fb6cd005aa))
* **phase-2:** transport layer as functions, backward compatible ([#95](https://github.com/zoedsoupe/anubis-mcp/issues/95)) ([7c45279](https://github.com/zoedsoupe/anubis-mcp/commit/7c45279af83ef907ee81fa66cb90b5ed51adec98))
* **phase-3:** server re-implementation and simplification ([#96](https://github.com/zoedsoupe/anubis-mcp/issues/96)) ([14c4e4f](https://github.com/zoedsoupe/anubis-mcp/commit/14c4e4f9ca17a8e932991efaedbdeab1c4b8bf22))
* **phase-4:** client extraction of handlers ([#100](https://github.com/zoedsoupe/anubis-mcp/issues/100)) ([dc0ea85](https://github.com/zoedsoupe/anubis-mcp/commit/dc0ea85aa17a864b645cf2e94c69f6dd1212d2fc))
* remove batch messaging feature ([#183](https://github.com/zoedsoupe/anubis-mcp/issues/183)) ([99458c0](https://github.com/zoedsoupe/anubis-mcp/commit/99458c0559d69addf9e22b3f7e38891e83d475de))
* tests ([#93](https://github.com/zoedsoupe/anubis-mcp/issues/93)) ([ca31feb](https://github.com/zoedsoupe/anubis-mcp/commit/ca31febee7aec1d45dcb32398b33228d1399ae39))


### Tests

* cut suite from 62s to 8s ([#149](https://github.com/zoedsoupe/anubis-mcp/issues/149)) ([7758cda](https://github.com/zoedsoupe/anubis-mcp/commit/7758cda6961722ad6539366253ddaeb518a5c2c4))
* fix the stdio cast message from server using a buffer ([4713234](https://github.com/zoedsoupe/anubis-mcp/commit/47132340bbc3487898234e3a491818130bc6b4ac))


### Continuous Integration

* add new elixir versions ([26dd267](https://github.com/zoedsoupe/anubis-mcp/commit/26dd267a1b3cb174120ecb0a47d4acdb067c4372))
* add pr-quality workflow ([d67eaa9](https://github.com/zoedsoupe/anubis-mcp/commit/d67eaa9882297ce1704841f908fe39cf6439206d))
* fix flaky test ([2f9dce3](https://github.com/zoedsoupe/anubis-mcp/commit/2f9dce3debc31bea8e69f1f2e7d7ae681b7a8e4a))
* fix zig correct version for burrito ([afec768](https://github.com/zoedsoupe/anubis-mcp/commit/afec7680ccafd3cdd2015aa16a2bd6f5ef266526))
* fix zig version for CLI release and locally on flake ([e7ed2b4](https://github.com/zoedsoupe/anubis-mcp/commit/e7ed2b4aa94cef5edf5968f30c24e5b1e4aac81e))
* use elixir 1.20.2 to publish hex pkg ([043710b](https://github.com/zoedsoupe/anubis-mcp/commit/043710b5594e40e01852a38f73406a542d5b60f6))
* use mlugg/setup-zig 0.15.2 in release-please auto build job ([428cace](https://github.com/zoedsoupe/anubis-mcp/commit/428cacea429a7cc881a384e40781d4d533a5ad31))

## [1.8.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.7.0...v1.8.0) (2026-07-16)

This release focuses on simplifying the runtime footprint and giving consumers more control over networking.

**⚠️ Breaking change:** the `Application` callback and the bundled CLI have been removed. If you relied on `anubis_mcp` starting supervision trees or processes automatically via `application/0`, you'll now need to start the relevant components explicitly in your own supervision tree. See the updated [README](https://github.com/zoedsoupe/anubis-mcp#readme) and [Introduction guide](https://github.com/zoedsoupe/anubis-mcp/blob/main/pages/introduction.md) for the new setup.

Alongside that, the Finch HTTP pool is now injectable, so you can plug in your own pool configuration (name, size, pool options) instead of relying on a globally started pool - handy for apps that already manage their own Finch instances or need per-tenant pools.

On the housekeeping side, example apps moved out of `lib/` into a dedicated root-level folder to keep the library package lean, and CI now publishes the Hex package using Elixir 1.20.2.

### Features

* add a serialize_assigns callback for server ([1059119](https://github.com/zoedsoupe/anubis-mcp/commit/10591197d5d25f090832790154af1a31974a681d)), closes [#199](https://github.com/zoedsoupe/anubis-mcp/issues/199)
* drop Application callback + CLI, make Finch pool injectable ([#224](https://github.com/zoedsoupe/anubis-mcp/issues/224)) ([b92a131](https://github.com/zoedsoupe/anubis-mcp/commit/b92a1319ac89f8faf15f3676f41e8183336f8869))


### Bug Fixes

* correctly append 2025-11-25 version to http transport ([889fa79](https://github.com/zoedsoupe/anubis-mcp/commit/889fa79244ec78fde8aeb5782c076163b1123a6e)), closes [#220](https://github.com/zoedsoupe/anubis-mcp/issues/220)
* correctly truncate tools args ([4e9288c](https://github.com/zoedsoupe/anubis-mcp/commit/4e9288cf5b2741cb2f3aa85a12769aedd9ad74ad))
* dedup protocol schema definitions ([a0314a2](https://github.com/zoedsoupe/anubis-mcp/commit/a0314a2844572375e05234c09f42f32603e98d80)), closes [#157](https://github.com/zoedsoupe/anubis-mcp/issues/157)


### Documentation

* revamp and rewrite ([0f459bb](https://github.com/zoedsoupe/anubis-mcp/commit/0f459bb209f8160c0339d0ce14fc53a4f8d5576a))


### Miscellaneous Chores

* move example apps to dedicated root folder ([631a929](https://github.com/zoedsoupe/anubis-mcp/commit/631a929a9778ea19cb862a4077512947bff8887c))
* remove dead llms.txt ([1e115b5](https://github.com/zoedsoupe/anubis-mcp/commit/1e115b5653567e5d066f20b7db3e598bad882262))


### Continuous Integration

* use elixir 1.20.2 to publish hex pkg ([a4d5f3c](https://github.com/zoedsoupe/anubis-mcp/commit/a4d5f3c6bfd06015a1c205390a80005ebe9c73ba))

## [1.7.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.6.2...v1.7.0) (2026-07-16)


### Features

* **streamable_http:** per-subscriber metadata and targeted sends ([#218](https://github.com/zoedsoupe/anubis-mcp/issues/218)) ([c606658](https://github.com/zoedsoupe/anubis-mcp/commit/c6066581fb7ff4a1665a8c2883ba675bd4f8b7a9))


### Bug Fixes

* Forward configured :headers on the DELETE session-teardown request (follow-up to [#180](https://github.com/zoedsoupe/anubis-mcp/issues/180)) ([#213](https://github.com/zoedsoupe/anubis-mcp/issues/213)) ([b32134a](https://github.com/zoedsoupe/anubis-mcp/commit/b32134a03fde24e8479d3e31d3459f9652136889))
* prevent "Server not initialized" race on first request ([#198](https://github.com/zoedsoupe/anubis-mcp/issues/198)) ([e84624c](https://github.com/zoedsoupe/anubis-mcp/commit/e84624cdf603ca65b26de77f253bdadf51a57079))
* **server:** resolve session names via Registry to prevent atom-exhaustion DoS ([#188](https://github.com/zoedsoupe/anubis-mcp/issues/188)) ([17e4a6d](https://github.com/zoedsoupe/anubis-mcp/commit/17e4a6d7d4c1baa90744b2c54392025b170a3f3a))
* **session:** trap_exit so terminate/2 runs on supervisor shutdown ([#209](https://github.com/zoedsoupe/anubis-mcp/issues/209)) ([6335cf4](https://github.com/zoedsoupe/anubis-mcp/commit/6335cf4d7a537204d99995c4b4eb675eaa3e3a83))
* **streamable_http:** don't close superseded SSE handler to prevent reconnect flap ([#215](https://github.com/zoedsoupe/anubis-mcp/issues/215)) ([a1e0ce6](https://github.com/zoedsoupe/anubis-mcp/commit/a1e0ce649b27198fe8a08ffa80ad68b8c840a9db))


### Continuous Integration

* add new elixir versions ([3b636a8](https://github.com/zoedsoupe/anubis-mcp/commit/3b636a8171560cd8a3a09591faf83c511f7cab30))
* add pr-quality workflow ([c0ca08f](https://github.com/zoedsoupe/anubis-mcp/commit/c0ca08f31bcac2ea322dd0c6249f8d7efa8ffcd3))
* fix zig correct version for burrito ([6e410bd](https://github.com/zoedsoupe/anubis-mcp/commit/6e410bd509031264c138cdf4ff0efd8aa27d491a))
* use mlugg/setup-zig 0.15.2 in release-please auto build job ([2ed6187](https://github.com/zoedsoupe/anubis-mcp/commit/2ed61875f87e464d20cbf8392d9c72933894755f))

## [1.6.2](https://github.com/zoedsoupe/anubis-mcp/compare/v1.6.1...v1.6.2) (2026-06-09)

### Bug Fixes

- forward :headers to SSE GET request ([#180](https://github.com/zoedsoupe/anubis-mcp/issues/180)) ([bb3280f](https://github.com/zoedsoupe/anubis-mcp/commit/bb3280f127084c627983b0c6b1ab4c87ec23c879))
- macros for Elixir 1.20 type checker compatibility ([48c9478](https://github.com/zoedsoupe/anubis-mcp/commit/48c947840e3bc60bc516d2a68cdacf6d2222b4b7))
- **streamable_http:** always advertise both content types on POST ([#178](https://github.com/zoedsoupe/anubis-mcp/issues/178)) ([66abc13](https://github.com/zoedsoupe/anubis-mcp/commit/66abc132e5c43993e260793eef1cb32ba152be26))

## [1.6.1](https://github.com/zoedsoupe/anubis-mcp/compare/v1.6.0...v1.6.1) (2026-05-23)

### Bug Fixes

- Echo request id in "Server not initialized" error ([#168](https://github.com/zoedsoupe/anubis-mcp/issues/168)) ([226b71e](https://github.com/zoedsoupe/anubis-mcp/commit/226b71ef92bd90216d79cd4998636b147763bf4b))

## [1.6.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.5.0...v1.6.0) (2026-05-18)

### Features

- add OAuth 2.1 authorization for MCP servers ([#158](https://github.com/zoedsoupe/anubis-mcp/issues/158)) ([a12a8f6](https://github.com/zoedsoupe/anubis-mcp/commit/a12a8f6ba9db8498a212f566898b66c99631993e))
- add Registry.PG for distributed session tracking via :pg ([#160](https://github.com/zoedsoupe/anubis-mcp/issues/160)) ([512e103](https://github.com/zoedsoupe/anubis-mcp/commit/512e1033aa6f868b33658395e6fe1f0e28c8faf8))

## [1.5.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.4.0...v1.5.0) (2026-05-09)

### Features

- MCP Tasks (2025-11-25) — server-receiver for tools/call ([#98](https://github.com/zoedsoupe/anubis-mcp/issues/98)) ([#155](https://github.com/zoedsoupe/anubis-mcp/issues/155)) ([51348f1](https://github.com/zoedsoupe/anubis-mcp/commit/51348f1a6e2b069fbe91c1cd50ce4610303de393))

### Bug Fixes

- drop compile-connected deps from component/1 macro ([#154](https://github.com/zoedsoupe/anubis-mcp/issues/154)) ([1e368b9](https://github.com/zoedsoupe/anubis-mcp/commit/1e368b906092b863362737a90f83ae5a35fd078f))

### Continuous Integration

- fix flaky test ([939fd76](https://github.com/zoedsoupe/anubis-mcp/commit/939fd769813a85170e3b59153a4b8e7f5804150e))

## [1.4.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.3.1...v1.4.0) (2026-05-08)

### Features

- add resource subscription capability implementation ([#152](https://github.com/zoedsoupe/anubis-mcp/issues/152)) ([10a09cf](https://github.com/zoedsoupe/anubis-mcp/commit/10a09cf89ffbd26651138c74961c442b6257cc40))
- dispatch session requests in supervised tasks ([#153](https://github.com/zoedsoupe/anubis-mcp/issues/153)) ([f0496b4](https://github.com/zoedsoupe/anubis-mcp/commit/f0496b41a40eb6fabd4e015ec3f0ed35575efd44))

### Tests

- cut suite from 62s to 8s ([#149](https://github.com/zoedsoupe/anubis-mcp/issues/149)) ([e5a86f5](https://github.com/zoedsoupe/anubis-mcp/commit/e5a86f592778b85d790a9ca41e577b56a2b3744d))

## [1.3.1](https://github.com/zoedsoupe/anubis-mcp/compare/v1.3.0...v1.3.1) (2026-05-04)

### Bug Fixes

- log sse_keepalive_failed at :warning, matching sse_send_failed ([#145](https://github.com/zoedsoupe/anubis-mcp/issues/145)) ([f8dbc43](https://github.com/zoedsoupe/anubis-mcp/commit/f8dbc43e2fc0fd9debd5851aebcb31ab459459bd))

### Miscellaneous Chores

- change setup-zig version on ci ([f77a844](https://github.com/zoedsoupe/anubis-mcp/commit/f77a844cd0c706db3240f1c655a7277969940244))

### Code Refactoring

- delegate JSON Schema to Peri, retire :mcp_field ([#146](https://github.com/zoedsoupe/anubis-mcp/issues/146)) ([9c674fd](https://github.com/zoedsoupe/anubis-mcp/commit/9c674fd44499a3a0c6ed271748ec7fb44fb4c914))

## [1.3.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.2.0...v1.3.0) (2026-04-29)

### Features

- **elicitation:** MCP 2025-06-18 elicitation support ([#139](https://github.com/zoedsoupe/anubis-mcp/issues/139)) ([8ab36e2](https://github.com/zoedsoupe/anubis-mcp/commit/8ab36e2f051984a9dc841e7f97e58542e5746800))
- resource templates with RFC 6570 URI matching ([#141](https://github.com/zoedsoupe/anubis-mcp/issues/141)) ([aaee374](https://github.com/zoedsoupe/anubis-mcp/commit/aaee37489887cd8725821a73b80f71ad21c626e2))

### Bug Fixes

- scope POST-with-SSE response to originating conn ([#144](https://github.com/zoedsoupe/anubis-mcp/issues/144)) ([5593006](https://github.com/zoedsoupe/anubis-mcp/commit/5593006ce6bbdcd9e6ce74aff1820247c807a463))

## [1.2.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.1.1...v1.2.0) (2026-04-24)

### Features

- pluggable session supervisor and :via tuple session naming ([#133](https://github.com/zoedsoupe/anubis-mcp/issues/133)) ([0a1aadc](https://github.com/zoedsoupe/anubis-mcp/commit/0a1aadc3b00be036980920a2c0e0a8ce55d2b392))

### Bug Fixes

- correct SSE task lifecycle bugs in StreamableHTTP transport ([#130](https://github.com/zoedsoupe/anubis-mcp/issues/130)) ([3a34382](https://github.com/zoedsoupe/anubis-mcp/commit/3a343828f3d6974fdbdeb9ab1589b9a52a56ad4f))
- defer streamable_http plug opts fetching to runtime ([#137](https://github.com/zoedsoupe/anubis-mcp/issues/137)) ([ad29215](https://github.com/zoedsoupe/anubis-mcp/commit/ad2921549529eac26488bdcf7be5c876c548e618))
- handle session expiry gracefully with optional callback and store restore ([#134](https://github.com/zoedsoupe/anubis-mcp/issues/134)) ([a42f462](https://github.com/zoedsoupe/anubis-mcp/commit/a42f4625f466ea46a490014d82c11ab8fde042dc))
- prevent lost SSE responses when client connection closes ([#132](https://github.com/zoedsoupe/anubis-mcp/issues/132)) ([f961fa0](https://github.com/zoedsoupe/anubis-mcp/commit/f961fa0719d795eeb2a629ae5764cbb8b29a4c1b))
- replace opaque KeyError with ArgumentError for missing :client_info ([#135](https://github.com/zoedsoupe/anubis-mcp/issues/135)) ([fc9444c](https://github.com/zoedsoupe/anubis-mcp/commit/fc9444cdab045e0275570dfb4f0ff6dcf1a42eb0))
- server stdio test againts custom io device ([#136](https://github.com/zoedsoupe/anubis-mcp/issues/136)) ([4b567d9](https://github.com/zoedsoupe/anubis-mcp/commit/4b567d99fa1dced884ddc89b6798a540e643ba2c))

## [1.1.1](https://github.com/zoedsoupe/anubis-mcp/compare/v1.1.0...v1.1.1) (2026-04-22)

### Bug Fixes

- buffer chunked STDIO responses before decoding in client ([#127](https://github.com/zoedsoupe/anubis-mcp/issues/127)) ([eff7f24](https://github.com/zoedsoupe/anubis-mcp/commit/eff7f248084077e081d57122648963a1ab24e35e))

### Miscellaneous Chores

- capture log from stdio transports processes ([fbcca0a](https://github.com/zoedsoupe/anubis-mcp/commit/fbcca0a1204e4e1602d8abe277af03f067338d10))
- encapsulate transport_parse_state into the Client.State struct ([602d74c](https://github.com/zoedsoupe/anubis-mcp/commit/602d74c7045e3087db4424ba55d61cfcf2c7f663))
- suppress SSE deprecation warnings ([05565fc](https://github.com/zoedsoupe/anubis-mcp/commit/05565fc030c449909bbdcb72d67773b9edefea9c))
- supress SSE deprecation warnings ([8334779](https://github.com/zoedsoupe/anubis-mcp/commit/833477912037a02972fff410aa646c9df7059f09))

### Tests

- fix the stdio cast message from server using a buffer ([76d7ecd](https://github.com/zoedsoupe/anubis-mcp/commit/76d7ecd52d8fc469615f4febe151d0cda11b3713))

## [1.1.0](https://github.com/zoedsoupe/anubis-mcp/compare/v1.0.0...v1.1.0) (2026-04-13)

### Features

- Add Client.await_ready/2 to block until MCP handshake completes ([#117](https://github.com/zoedsoupe/anubis-mcp/issues/117)) ([4c48647](https://github.com/zoedsoupe/anubis-mcp/commit/4c48647192c3304e012049669729008d7177940e))
- add instructions field to initialize response ([#122](https://github.com/zoedsoupe/anubis-mcp/issues/122)) ([8103b7c](https://github.com/zoedsoupe/anubis-mcp/commit/8103b7c5cbc12ace1e302edd059e42c0a04618f1))

### Documentation

- correct supervision tree setup ([#118](https://github.com/zoedsoupe/anubis-mcp/issues/118)) ([ae2560a](https://github.com/zoedsoupe/anubis-mcp/commit/ae2560a8a7fd85847557ac21fc978e15dc5f7995))

## [1.0.0](https://github.com/zoedsoupe/anubis-mcp/compare/v0.17.1...v1.0.0) (2026-03-16)

### ⚠ BREAKING CHANGES

- remove client base module and client macro ([#110](https://github.com/zoedsoupe/anubis-mcp/issues/110))
- **phase-3:** server re-implementation and simplification ([#96](https://github.com/zoedsoupe/anubis-mcp/issues/96))

### Features

- add _meta support to Tool struct and JSON encoder ([#108](https://github.com/zoedsoupe/anubis-mcp/issues/108)) ([6ac49d1](https://github.com/zoedsoupe/anubis-mcp/commit/6ac49d181baed767defe9fc5138c6d41caa26f20))

### Bug Fixes

- **phase-5:** remove dead code and update docs ([#104](https://github.com/zoedsoupe/anubis-mcp/issues/104)) ([eea86af](https://github.com/zoedsoupe/anubis-mcp/commit/eea86af23dcb805a7770894c6a6a897700c38dfe))
- regression for input/output server schema ([85f8ebb](https://github.com/zoedsoupe/anubis-mcp/commit/85f8ebb7439c51ab5cb0df974e08720833f534e9))
- remove client base module and client macro ([#110](https://github.com/zoedsoupe/anubis-mcp/issues/110)) ([1f9f13c](https://github.com/zoedsoupe/anubis-mcp/commit/1f9f13cf2c44294391dd580030a1210dcd349fd5))
- server examples and sse server transport ([944bafb](https://github.com/zoedsoupe/anubis-mcp/commit/944bafb01c29afa36a82eddc81c6e1c6d0278a9c))
- session serializion errors ([#112](https://github.com/zoedsoupe/anubis-mcp/issues/112)) ([cb8c0e3](https://github.com/zoedsoupe/anubis-mcp/commit/cb8c0e31ad831484425e378951a85591c8cbf29f)), closes [#60](https://github.com/zoedsoupe/anubis-mcp/issues/60)
- Start SSE keepalive when first handler is registered ([#83](https://github.com/zoedsoupe/anubis-mcp/issues/83)) ([c3c01e9](https://github.com/zoedsoupe/anubis-mcp/commit/c3c01e975f57ef421783f963adf717b522b5c724))
- stdio server transport working ([#111](https://github.com/zoedsoupe/anubis-mcp/issues/111)) ([b331281](https://github.com/zoedsoupe/anubis-mcp/commit/b33128172db3f4ec3766cb4c7125f83bc3a85dd7))

### Code Refactoring

- **phase-3:** server re-implementation and simplification ([#96](https://github.com/zoedsoupe/anubis-mcp/issues/96)) ([badb0f0](https://github.com/zoedsoupe/anubis-mcp/commit/badb0f0111521f8bd5a5dba32574c25e1b589c91))
- **phase-4:** client extraction of handlers ([#100](https://github.com/zoedsoupe/anubis-mcp/issues/100)) ([08b98c0](https://github.com/zoedsoupe/anubis-mcp/commit/08b98c03e50d698a781507ee63a4a6c5f8cdcb5e))

## [0.17.1](https://github.com/zoedsoupe/anubis-mcp/compare/v0.17.0...v0.17.1) (2026-02-28)

### Bug Fixes

- Check Process.alive? before sending to SSE handler ([#82](https://github.com/zoedsoupe/anubis-mcp/issues/82)) ([e1dc705](https://github.com/zoedsoupe/anubis-mcp/commit/e1dc705f1ae8ee7e8670d26c7fdfc30583d19efd))

### Code Refactoring

- **phase-1:** abstract protocol version negotiation ([#93](https://github.com/zoedsoupe/anubis-mcp/issues/93)) ([05a2362](https://github.com/zoedsoupe/anubis-mcp/commit/05a2362a672ef462e73bc9a3f637c3f203c0978e))
- **phase-2:** transport layer as functions, backward compatible ([#95](https://github.com/zoedsoupe/anubis-mcp/issues/95)) ([105d6a9](https://github.com/zoedsoupe/anubis-mcp/commit/105d6a91e31d8dbf606ec7916317f9add94acf4e))

## [0.17.0](https://github.com/zoedsoupe/anubis-mcp/compare/v0.16.0...v0.17.0) (2025-12-09)

### Features

- **redis:** add redix_opts for SSL/TLS support ([#59](https://github.com/zoedsoupe/anubis-mcp/issues/59)) ([33658ab](https://github.com/zoedsoupe/anubis-mcp/commit/33658abab69e1f0c361a4dbf4e9665bb900d2f7e))

### Bug Fixes

- added server component description/0 callback ([#58](https://github.com/zoedsoupe/anubis-mcp/issues/58)) ([a094473](https://github.com/zoedsoupe/anubis-mcp/commit/a094473916f7ac414369bb2faab1593fd141a7f1))
- redix should be loaded ([#71](https://github.com/zoedsoupe/anubis-mcp/issues/71)) ([09b872f](https://github.com/zoedsoupe/anubis-mcp/commit/09b872fe5dc48665beee3be8a7b7ae9943ce48ae))

## [0.16.0](https://github.com/zoedsoupe/anubis-mcp/compare/v0.15.0...v0.16.0) (2025-11-18)

### Features

- redis based session store (continue from [#48](https://github.com/zoedsoupe/anubis-mcp/issues/48)) ([#55](https://github.com/zoedsoupe/anubis-mcp/issues/55)) ([fddea32](https://github.com/zoedsoupe/anubis-mcp/commit/fddea327ef8d91c57c4dc65f527aadc3e8d105a2))

### Bug Fixes

- correct arguments in Logging.should_log? ([#47](https://github.com/zoedsoupe/anubis-mcp/issues/47)) ([6f550e6](https://github.com/zoedsoupe/anubis-mcp/commit/6f550e647fd5e6e7c6cdfb233e1cc8a4ac530fc7))

## [0.15.0](https://github.com/zoedsoupe/anubis-mcp/compare/v0.14.1...v0.15.0) (2025-11-03)

### Features

- add timeout for client/server -&gt; transport calling option ([#50](https://github.com/zoedsoupe/anubis-mcp/issues/50)) ([1e37c23](https://github.com/zoedsoupe/anubis-mcp/commit/1e37c23d3af3f40c54e0ba8b1bcc5043d80547d1))
- allow template resources registration ([#43](https://github.com/zoedsoupe/anubis-mcp/issues/43)) ([9af9b8d](https://github.com/zoedsoupe/anubis-mcp/commit/9af9b8dcf4368ba981b667acc86b47b45a7d8ff4))

### Bug Fixes

- Timeout options not properly passed to HTTP transport ([#52](https://github.com/zoedsoupe/anubis-mcp/issues/52)) ([0d392d6](https://github.com/zoedsoupe/anubis-mcp/commit/0d392d64010e39f4ce38a4427b960574fa6e82aa))

## [0.14.1](https://github.com/zoedsoupe/anubis-mcp/compare/v0.14.0...v0.14.1) (2025-10-07)

### Bug Fixes

- correct capability parsing to nest options under capability keys ([#31](https://github.com/zoedsoupe/anubis-mcp/issues/31)) ([9946027](https://github.com/zoedsoupe/anubis-mcp/commit/9946027072aee81297ee3c6c10e75acbb1328ae3))
- correctly handle timeouts and keepalive ([#41](https://github.com/zoedsoupe/anubis-mcp/issues/41)) ([2f44840](https://github.com/zoedsoupe/anubis-mcp/commit/2f448404601799a061c9971bee69222d9c7bf927))

### Documentation

- rewrite introduction/home documentation page ([34baf39](https://github.com/zoedsoupe/anubis-mcp/commit/34baf3907e7e50b490398f48c32a782d213c36e9))

### Miscellaneous Chores

- add sponsors section with coderabbit ([f04f8bb](https://github.com/zoedsoupe/anubis-mcp/commit/f04f8bb100eb03602fd59716936ce2353040f4b2))
- update example projects elixir deps, use fixed otp version and stable version for CLI release ([b362e54](https://github.com/zoedsoupe/anubis-mcp/commit/b362e54594d1551856436eb401a394be33dbf3a6))

### Continuous Integration

- fix zig version for CLI release and locally on flake ([e7ed2b4](https://github.com/zoedsoupe/anubis-mcp/commit/e7ed2b4aa94cef5edf5968f30c24e5b1e4aac81e))

## [0.14.0](https://github.com/zoedsoupe/anubis-mcp/compare/v0.13.1...v0.14.0) (2025-08-21)

### Features

- `resources/templates/list` method for clients ([a6eb210](https://github.com/zoedsoupe/anubis-mcp/commit/a6eb210af4b6913d8a8480e5247002c2b15f511c))

### Bug Fixes

- align docs and parsing of server component schema-field definition options ([#12](https://github.com/zoedsoupe/anubis-mcp/issues/12)) ([cb2df76](https://github.com/zoedsoupe/anubis-mcp/commit/cb2df761e05beacf2beb3d5e94bf56329c203cc7))
- correctly pass server call timeout options ([a49f497](https://github.com/zoedsoupe/anubis-mcp/commit/a49f4973545860e98fa056655ff229df70c70749))
- explicit handle title for components ([#9](https://github.com/zoedsoupe/anubis-mcp/issues/9)) ([1adfed2](https://github.com/zoedsoupe/anubis-mcp/commit/1adfed2f0e18a4cd2dc7d013556455a155a8ff7f))
- output schemas should not validate on error resps ([#15](https://github.com/zoedsoupe/anubis-mcp/issues/15)) ([b5faaad](https://github.com/zoedsoupe/anubis-mcp/commit/b5faaad5c409b3616273d5bee822d609ef35803b))

### Reverts

- "Add keep-alive messages to the StreamableHTTP transport ([#11](https://github.com/zoedsoupe/anubis-mcp/issues/11))" ([8ea5a3c](https://github.com/zoedsoupe/anubis-mcp/commit/8ea5a3c8edd31394b4f47cb3e4f73f06d8d12fed))

### Miscellaneous Chores

- rename hermes folders/files to anubis ([#5](https://github.com/zoedsoupe/anubis-mcp/issues/5)) ([239ee3f](https://github.com/zoedsoupe/anubis-mcp/commit/239ee3f611fd9ba3a8234ee8155da1cb9a8b89c7))

## [0.13.1](https://github.com/zoedsoupe/anubis-mcp/compare/v0.13.0...v0.13.1) (2025-07-31)

### Bug Fixes

- not crash server on empty tool/prompt args ([#4](https://github.com/zoedsoupe/anubis-mcp/issues/4)) ([ee8043f](https://github.com/zoedsoupe/anubis-mcp/commit/ee8043f331481790931d2d711b6df8f9cd7a4940))

### Miscellaneous Chores

- old release are from the original fork ([e99d8ba](https://github.com/zoedsoupe/anubis-mcp/commit/e99d8baa7e8c00f3105ce16f8ac2178698859278))
- plug router config on readme ([#2](https://github.com/zoedsoupe/anubis-mcp/issues/2)) ([243176c](https://github.com/zoedsoupe/anubis-mcp/commit/243176cd95fdb3ac0a500630b4e80cc26bc33769))
- readme ([bed6ff7](https://github.com/zoedsoupe/anubis-mcp/commit/bed6ff78ed617af3eaba6d316c1107643e8aea06))

## [0.13.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.12.1...v0.13.0) (2025-07-18)

### Features

- allow redact patterns on server assigns/data ([#190](https://github.com/cloudwalk/hermes-mcp/issues/190)) ([07af99f](https://github.com/cloudwalk/hermes-mcp/commit/07af99f9e43d2afa87bf5504437ecf21c346a1d7))
- better dsl for embedded nested fields on server components ([#199](https://github.com/cloudwalk/hermes-mcp/issues/199)) ([097f5fd](https://github.com/cloudwalk/hermes-mcp/commit/097f5fd8f788aaaa73c5e3d6699937656488886f))
- new server response contents for tools/resources with annotations (2025-06-18) ([#195](https://github.com/cloudwalk/hermes-mcp/issues/195)) ([9b65308](https://github.com/cloudwalk/hermes-mcp/commit/9b653087a6ddfac399b33be2c4be54d564335c84))
- resources templates ([#193](https://github.com/cloudwalk/hermes-mcp/issues/193)) ([1457e59](https://github.com/cloudwalk/hermes-mcp/commit/1457e59f16b77ca894b07a731d69ca5f8337c42b))
- tools output schema feature (2025-06-18) ([#194](https://github.com/cloudwalk/hermes-mcp/issues/194)) ([8088a49](https://github.com/cloudwalk/hermes-mcp/commit/8088a49ce4463a01e899418bb9c34fce30427d3c))

### Miscellaneous Chores

- deprecate sse transport ([#187](https://github.com/cloudwalk/hermes-mcp/issues/187)) ([1932fbc](https://github.com/cloudwalk/hermes-mcp/commit/1932fbcdef12194c496d3ac074b17ef65fe18e49))
- **deps:** bump the npm_and_yarn group across 1 directory with 2 updates ([#198](https://github.com/cloudwalk/hermes-mcp/issues/198)) ([5e21aac](https://github.com/cloudwalk/hermes-mcp/commit/5e21aac07ab1e709cb2bad8ddf9f45ba3ff99ef9))
- readme ([bed6ff7](https://github.com/cloudwalk/hermes-mcp/commit/bed6ff78ed617af3eaba6d316c1107643e8aea06))

## [0.12.1](https://github.com/cloudwalk/hermes-mcp/compare/v0.12.0...v0.12.1) (2025-07-14)

### Code Refactoring

- do not hangle on transport process ([#185](https://github.com/cloudwalk/hermes-mcp/issues/185)) ([e6ba926](https://github.com/cloudwalk/hermes-mcp/commit/e6ba9260ceb8e078ca043d6f1ceb41d540b42ca0))
- remove batch messaging feature ([#183](https://github.com/cloudwalk/hermes-mcp/issues/183)) ([99458c0](https://github.com/cloudwalk/hermes-mcp/commit/99458c0559d69addf9e22b3f7e38891e83d475de))

## [0.12.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.11.3...v0.12.0) (2025-07-11)

### Features

- client sampling capability ([#170](https://github.com/cloudwalk/hermes-mcp/issues/170)) ([da617a6](https://github.com/cloudwalk/hermes-mcp/commit/da617a694dbeff1d363e7b671a31f484e202e685))
- roots/list and completion features ([#178](https://github.com/cloudwalk/hermes-mcp/issues/178)) ([d22a6bd](https://github.com/cloudwalk/hermes-mcp/commit/d22a6bdfb92189e54455c49120abc2c7fa4f8814))
- server components cursor pagination ([#177](https://github.com/cloudwalk/hermes-mcp/issues/177)) ([a95eba7](https://github.com/cloudwalk/hermes-mcp/commit/a95eba7cc2ffcefca99b3961b80094bb12a3912f))
- server-side sampling capability ([#173](https://github.com/cloudwalk/hermes-mcp/issues/173)) ([c09e7f3](https://github.com/cloudwalk/hermes-mcp/commit/c09e7f3a5e95e59f5644ef12e1602b3b8621df7f))

### Bug Fixes

- allow configuring server request timeout ([#182](https://github.com/cloudwalk/hermes-mcp/issues/182)) ([e79fe2f](https://github.com/cloudwalk/hermes-mcp/commit/e79fe2f003a41517a5ff5e8f6e3fb378bdc43f11))
- do not allow duplicate server components and more convenient API ([#180](https://github.com/cloudwalk/hermes-mcp/issues/180)) ([bc71df8](https://github.com/cloudwalk/hermes-mcp/commit/bc71df8f7c6fb877f19dada9b17c3eb342d32ccd))

### Miscellaneous Chores

- add llms summary about the library ([#175](https://github.com/cloudwalk/hermes-mcp/issues/175)) ([ed0e608](https://github.com/cloudwalk/hermes-mcp/commit/ed0e60872e5b77ddb6ffff13da6c1e20b1c2d7a2))
- allow different kind of components have the same name ([#181](https://github.com/cloudwalk/hermes-mcp/issues/181)) ([d5ba6f5](https://github.com/cloudwalk/hermes-mcp/commit/d5ba6f56fb54ed07e46d37c2217dcf76c793762f))

### Code Refactoring

- handle_sampling callback, use frame as entrypoint for notifications ([#176](https://github.com/cloudwalk/hermes-mcp/issues/176)) ([1e88711](https://github.com/cloudwalk/hermes-mcp/commit/1e887117ba81751042534d60df79d83a8123a3d9))
- interactive tasks now support JSON file input ([#172](https://github.com/cloudwalk/hermes-mcp/issues/172)) ([9465266](https://github.com/cloudwalk/hermes-mcp/commit/946526617171094ccf929a5d9f3bbd8e3a591f18))

## [0.11.3](https://github.com/cloudwalk/hermes-mcp/compare/v0.11.2...v0.11.3) (2025-07-02)

### Bug Fixes

- correctly parse dates when default values are passed ([58f6368](https://github.com/cloudwalk/hermes-mcp/commit/58f63686574e230269f847ee793d9561976653bb))
- include frame helpers on module-based component ([#163](https://github.com/cloudwalk/hermes-mcp/issues/163)) ([15ba2c7](https://github.com/cloudwalk/hermes-mcp/commit/15ba2c7fbdd0a776eabe028aef0350f4f52a43a8))
- server can now send notifications correctly ([#166](https://github.com/cloudwalk/hermes-mcp/issues/166)) ([33f32de](https://github.com/cloudwalk/hermes-mcp/commit/33f32deccd42dc4591832636b2b3fad56ce40661))

### Miscellaneous Chores

- update documentation, simplify, more storytelling ([#168](https://github.com/cloudwalk/hermes-mcp/issues/168)) ([ccdddc1](https://github.com/cloudwalk/hermes-mcp/commit/ccdddc1478c09e2f3440a6f1343949aeca854a1d))

## [0.11.2](https://github.com/cloudwalk/hermes-mcp/compare/v0.11.1...v0.11.2) (2025-06-30)

### Bug Fixes

- correctly parse peri numeric contrainsts to json-schema ([#160](https://github.com/cloudwalk/hermes-mcp/issues/160)) ([808c2c0](https://github.com/cloudwalk/hermes-mcp/commit/808c2c09e490bf9a866d5575abbf08d355c8324b))
- interactive http tasks should accept custom headers ([#159](https://github.com/cloudwalk/hermes-mcp/issues/159)) ([c2fe91e](https://github.com/cloudwalk/hermes-mcp/commit/c2fe91eff5a701e42a636ee1a291ea51a93f7983))

## [0.11.1](https://github.com/cloudwalk/hermes-mcp/compare/v0.11.0...v0.11.1) (2025-06-30)

### Bug Fixes

- loggin should respect the logger config ([#157](https://github.com/cloudwalk/hermes-mcp/issues/157)) ([0fbf6a6](https://github.com/cloudwalk/hermes-mcp/commit/0fbf6a652ed9dd5da64716d47ece675192442ea0))

## [0.11.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.5...v0.11.0) (2025-06-30)

### Features

- runtime server components, simplified api ([#153](https://github.com/cloudwalk/hermes-mcp/issues/153)) ([8af35d6](https://github.com/cloudwalk/hermes-mcp/commit/8af35d67cd15d125e40ab9b115ff6900c3487ea5))

### Bug Fixes

- allow users to control external process messages ([#149](https://github.com/cloudwalk/hermes-mcp/issues/149)) ([8fef4eb](https://github.com/cloudwalk/hermes-mcp/commit/8fef4eb753f38a325a1d3a94c310e5fd1c478ede))
- correctly encode prompt/resource ([#155](https://github.com/cloudwalk/hermes-mcp/issues/155)) ([4249b13](https://github.com/cloudwalk/hermes-mcp/commit/4249b137e43587862de2e59acba4660ac785702a))
- more genserver mcp server callbacks, plug based startup and documentation ([#152](https://github.com/cloudwalk/hermes-mcp/issues/152)) ([9c26b1c](https://github.com/cloudwalk/hermes-mcp/commit/9c26b1ce4d033e3c69bc872a5ed01a037ec68f59))
- server behaviour with optional callbacks ([#151](https://github.com/cloudwalk/hermes-mcp/issues/151)) ([91aa191](https://github.com/cloudwalk/hermes-mcp/commit/91aa1916f28da5972f6b100861a2547697c1ddb7))

### Code Refactoring

- improve runtime components schema def ([#154](https://github.com/cloudwalk/hermes-mcp/issues/154)) ([96ff2a9](https://github.com/cloudwalk/hermes-mcp/commit/96ff2a97be02f0f35ee4a288838a1dbf518bbac3))

## [0.10.5](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.4...v0.10.5) (2025-06-25)

### Bug Fixes

- normalize transport api ([#146](https://github.com/cloudwalk/hermes-mcp/issues/146)) ([8a30a34](https://github.com/cloudwalk/hermes-mcp/commit/8a30a34c944ca4d85de622f9063a558bd495c6fc)), closes [#145](https://github.com/cloudwalk/hermes-mcp/issues/145)

## [0.10.4](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.3...v0.10.4) (2025-06-24)

### Bug Fixes

- server session expiration on idle (configurable) ([#143](https://github.com/cloudwalk/hermes-mcp/issues/143)) ([d9f7164](https://github.com/cloudwalk/hermes-mcp/commit/d9f7164028b2b6e8ff3d697f888adf655110bc1f))

## [0.10.3](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.2...v0.10.3) (2025-06-23)

### Bug Fixes

- include formatter on hex release ([#139](https://github.com/cloudwalk/hermes-mcp/issues/139)) ([d91b244](https://github.com/cloudwalk/hermes-mcp/commit/d91b244aeed4211a6653a82705b03da2247db9a3))

## [0.10.2](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.1...v0.10.2) (2025-06-23)

### Bug Fixes

- default implementation for server handle_notification ([#135](https://github.com/cloudwalk/hermes-mcp/issues/135)) ([c958041](https://github.com/cloudwalk/hermes-mcp/commit/c9580410162c31a62190631f6702024ea3458beb))

### Code Refactoring

- cleaner peri integration ([#137](https://github.com/cloudwalk/hermes-mcp/issues/137)) ([43226cc](https://github.com/cloudwalk/hermes-mcp/commit/43226cc9fb2f49edfbf8685fe181eb3093304308)), closes [#123](https://github.com/cloudwalk/hermes-mcp/issues/123)

## [0.10.1](https://github.com/cloudwalk/hermes-mcp/compare/v0.10.0...v0.10.1) (2025-06-21)

### Bug Fixes

- client should send both sse/json headers on POST requests ([#134](https://github.com/cloudwalk/hermes-mcp/issues/134)) ([e906b7f](https://github.com/cloudwalk/hermes-mcp/commit/e906b7f02bf390faecc2b6bd39aab05ef9c500b1))
- correctly allows macro-based/callback-based server implementations ([#131](https://github.com/cloudwalk/hermes-mcp/issues/131)) ([d7bfc75](https://github.com/cloudwalk/hermes-mcp/commit/d7bfc7541a8c381573f1a20ebc37d4a7dbaaa139))
- remove last uses of hard-coded Anubis.Server.Registry ([cc0ffd9](https://github.com/cloudwalk/hermes-mcp/commit/cc0ffd95fce771a9c861c6859124dcedb6ceb88e))

## [0.10.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.9.1...v0.10.0) (2025-06-18)

### Features

- batch operations on server-side ([#125](https://github.com/cloudwalk/hermes-mcp/issues/125)) ([28eea7c](https://github.com/cloudwalk/hermes-mcp/commit/28eea7cd15f72c4effccc8475e6b301b2cd9745c))
- missing notifications handlers ([#129](https://github.com/cloudwalk/hermes-mcp/issues/129)) ([34d5934](https://github.com/cloudwalk/hermes-mcp/commit/34d593499fdd846f430b93b4c52ca986f345646d))
- support batch operations on client side ([#101](https://github.com/cloudwalk/hermes-mcp/issues/101)) ([fadf28d](https://github.com/cloudwalk/hermes-mcp/commit/fadf28d80068f3f1e77835fd46a276338048f0bc))
- tools annotations ([#127](https://github.com/cloudwalk/hermes-mcp/issues/127)) ([c83e8f1](https://github.com/cloudwalk/hermes-mcp/commit/c83e8f1b0e721b1a03960ac67cdd0774337675dc))

### Miscellaneous Chores

- release please correct version on readme ([#128](https://github.com/cloudwalk/hermes-mcp/issues/128)) ([d0125c6](https://github.com/cloudwalk/hermes-mcp/commit/d0125c664b5190b560bb988ff01d17cbdba814bd))
- update peri ([#126](https://github.com/cloudwalk/hermes-mcp/issues/126)) ([7292615](https://github.com/cloudwalk/hermes-mcp/commit/7292615cf57da0185006df2f6221f8ab93aacd30))

## [0.9.1](https://github.com/cloudwalk/hermes-mcp/compare/v0.9.0...v0.9.1) (2025-06-13)

### Bug Fixes

- allow enum specific type on json-schema ([#121](https://github.com/cloudwalk/hermes-mcp/issues/121)) ([23c9ce2](https://github.com/cloudwalk/hermes-mcp/commit/23c9ce2081ed1099ce1f3afbd9318c8a02480039)), closes [#114](https://github.com/cloudwalk/hermes-mcp/issues/114)
- correctly escape quoted expressions ([#119](https://github.com/cloudwalk/hermes-mcp/issues/119)) ([0c469c5](https://github.com/cloudwalk/hermes-mcp/commit/0c469c552d8d5fd2498706b4b1f41100e8561e2f)), closes [#118](https://github.com/cloudwalk/hermes-mcp/issues/118)

## [0.9.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.8.2...v0.9.0) (2025-06-12)

### Features

- add independently configurable logs ([#113](https://github.com/cloudwalk/hermes-mcp/issues/113)) ([bb0be27](https://github.com/cloudwalk/hermes-mcp/commit/bb0be2716ac41bf43814a16497b209fa55cc811b))

### Bug Fixes

- allow registering a name for the client supervisor ([#117](https://github.com/cloudwalk/hermes-mcp/issues/117)) ([d356511](https://github.com/cloudwalk/hermes-mcp/commit/d356511e2fbcf47b6a85ed733671e96d800ac693))

## [0.8.2](https://github.com/cloudwalk/hermes-mcp/compare/v0.8.1...v0.8.2) (2025-06-11)

### Code Refactoring

- higher-level client implementation ([#111](https://github.com/cloudwalk/hermes-mcp/issues/111)) ([5de2162](https://github.com/cloudwalk/hermes-mcp/commit/5de2162b166e390b4dacfd7b9960fab59c81b4d7))

## [0.8.1](https://github.com/cloudwalk/hermes-mcp/compare/v0.8.0...v0.8.1) (2025-06-10)

### Bug Fixes

- anubis should respect mix releases startup ([#109](https://github.com/cloudwalk/hermes-mcp/issues/109)) ([f42d476](https://github.com/cloudwalk/hermes-mcp/commit/f42d476e1dc05c57479170bd58aaca9028ef1e66))

## [0.8.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.7.0...v0.8.0) (2025-06-10)

### Features

- inject user and transport data on mcp server frame ([#106](https://github.com/cloudwalk/hermes-mcp/issues/106)) ([feb2ce3](https://github.com/cloudwalk/hermes-mcp/commit/feb2ce308e9fd0cde4118b294dd47ce64d8db18f))
- legacy sse server transport ([#102](https://github.com/cloudwalk/hermes-mcp/issues/102)) ([4a71088](https://github.com/cloudwalk/hermes-mcp/commit/4a71088713071a726bde03bf1385c3c794d2134b))

### Bug Fixes

- allow empty capabilities on incoming JSON-RPC messages ([#105](https://github.com/cloudwalk/hermes-mcp/issues/105)) ([f0ad4cf](https://github.com/cloudwalk/hermes-mcp/commit/f0ad4cf1a5a85cc8a56baed875d2d2d200bb5860)), closes [#96](https://github.com/cloudwalk/hermes-mcp/issues/96)

### Miscellaneous Chores

- release please should include all files ([#108](https://github.com/cloudwalk/hermes-mcp/issues/108)) ([d0a25b9](https://github.com/cloudwalk/hermes-mcp/commit/d0a25b968c83ae1023ffffc8ee07b5b490122c03))

## [0.7.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.6.0...v0.7.0) (2025-06-09)

### Features

- allow json schema fields on tools/prompts definition ([#99](https://github.com/cloudwalk/hermes-mcp/issues/99)) ([0345f12](https://github.com/cloudwalk/hermes-mcp/commit/0345f122484a0169645c5da07e50c2d64fd6c5f5))

## [0.6.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.5.0...v0.6.0) (2025-06-09)

### Features

- allow customize server registry impl ([#94](https://github.com/cloudwalk/hermes-mcp/issues/94)) ([f3ac087](https://github.com/cloudwalk/hermes-mcp/commit/f3ac08749a7c361466a7a619f9782e8d8706a7b6))
- mcp high level server components definition ([#91](https://github.com/cloudwalk/hermes-mcp/issues/91)) ([007f41d](https://github.com/cloudwalk/hermes-mcp/commit/007f41d33874fd9f1b5e340ecbe16317dc3576b7))
- mcp server handlers refactored ([#92](https://github.com/cloudwalk/hermes-mcp/issues/92)) ([e213e04](https://github.com/cloudwalk/hermes-mcp/commit/e213e046b1360b24ff9e42835cdf80f5fe2ae4fa))

### Bug Fixes

- correctly handle mcp requests on phoenix apps ([#88](https://github.com/cloudwalk/hermes-mcp/issues/88)) ([09f4235](https://github.com/cloudwalk/hermes-mcp/commit/09f42359f0daac694013f0be4f6a74de2be7f4ff)), closes [#86](https://github.com/cloudwalk/hermes-mcp/issues/86)

### Miscellaneous Chores

- upcate automatic version ([#98](https://github.com/cloudwalk/hermes-mcp/issues/98)) ([0c08233](https://github.com/cloudwalk/hermes-mcp/commit/0c08233371338af24ea66047b4e1a8e9fa5cb055))

### Code Refactoring

- tests ([#93](https://github.com/cloudwalk/hermes-mcp/issues/93)) ([ca31feb](https://github.com/cloudwalk/hermes-mcp/commit/ca31febee7aec1d45dcb32398b33228d1399ae39))

## [0.5.0](https://github.com/cloudwalk/hermes-mcp/compare/v0.4.1...v0.5.0) (2025-06-05)

### Features

- client support new mcp spec ([#83](https://github.com/cloudwalk/hermes-mcp/issues/83)) ([73d14f7](https://github.com/cloudwalk/hermes-mcp/commit/73d14f77522cef0f7212230c05cdac23ee2d93e2))
- enable log disabling ([#78](https://github.com/cloudwalk/hermes-mcp/issues/78)) ([fa1453f](https://github.com/cloudwalk/hermes-mcp/commit/fa1453fee9b015c0ad7f9ac223749a9c9f1fcf6a))
- low level genservy mcp server implementation (stdio + stremable http) ([#77](https://github.com/cloudwalk/hermes-mcp/issues/77)) ([e6606b4](https://github.com/cloudwalk/hermes-mcp/commit/e6606b4d66a2d7ddeb6c32e0041c22d4f0036ac5))
- mvp higher level mcp server definition ([#84](https://github.com/cloudwalk/hermes-mcp/issues/84)) ([a5fec1c](https://github.com/cloudwalk/hermes-mcp/commit/a5fec1c976595c3363d4eec83e0cbc382eac9207))

### Code Refactoring

- base mcp server implementation correctly uses streamable http ([#85](https://github.com/cloudwalk/hermes-mcp/issues/85)) ([29060fd](https://github.com/cloudwalk/hermes-mcp/commit/29060fd2d2e383c58c727a9085b30162c6b8179a))

## [0.4.0](https://github.com/cloudwalk/hermes-mcp) - 2025-05-06

### Added

- Implemented WebSocket transport (#70)
- Emit `telemetry` events (#54)
- Implement client feature `completion` request (#72)
- Implement client feature roots, server requests (#73)

## [0.3.12](https://github.com/cloudwalk/hermes-mcp) - 2025-04-24

### Fixed

- Correctly handles "nested" timeouts (genserver vs MCP) (#71)

## [0.3.11](https://github.com/cloudwalk/hermes-mcp) - 2025-04-17

### Added

- Improved core library logging and added verbosity level on interactive/CLI (#68)

## [0.3.10](https://github.com/cloudwalk/hermes-mcp) - 2025-04-17

### Fixed

- Handle SSE ping and reconnect events from server (#65)

## [0.3.9](https://github.com/cloudwalk/hermes-mcp) - 2025-04-15

### Fixed

- Improved and simplified SSE endpoint event URI merging (#64)

### Added

- Added internal client/transport state inspection on CLI/mix tasks (#61)

## [0.3.8](https://github.com/cloudwalk/hermes-mcp) - 2025-04-10

### Added

- Created `Operation` struct to standardize client API calls (#56)
- Fixed ERTS version to avoid release errors

### Fixed

- Resolved client timeout confusion by standardizing timeout handling (#42)

## [0.3.7](https://github.com/cloudwalk/hermes-mcp) - 2025-04-01

### Fixed

- Client reinitialization from interactive CLI (#55)

## [0.3.6](https://github.com/cloudwalk/hermes-mcp) - 2025-03-28

### Added

- New roadmap and protocol update proposal (#53)
- Added documentation for the 2025-03-26 protocol update

## [0.3.5](https://github.com/cloudwalk/hermes-mcp) - 2025-03-25

### Documentation

- Added Roadmap to README (#47)

## [0.3.4](https://github.com/cloudwalk/hermes-mcp) - 2025-03-20

### Added

- `help` command and flag on the interactive CLI (#37)
- improve SSE connection status on interactive task/cli (#37)

## [0.3.3](https://github.com/cloudwalk/hermes-mcp) - 2025-03-20

### Added

- Client request cancellation support (#35)
- Improved URI path handling for SSE transport (#36)
- Enhanced interactive mix tasks for testing MCP servers (#34)

## [0.3.2](https://github.com/cloudwalk/hermes-mcp) - 2025-03-19

### Added

- Ship static binaries to use anubis-mcp as standalone application

## [0.3.1](https://github.com/cloudwalk/hermes-mcp) - 2025-03-19

### Added

- Ship interactive mix tasks `stdio.interactive` and `sse.interactive` to test MCP servers

## [0.3.0](https://github.com/cloudwalk/hermes-mcp) - 2025-03-18

### Added

- Structured server-client logging support (#27)
- Progress notification tracking (#26)
- MCP domain model implementation (#28)
- Comprehensive SSE unit tests (#20)
- Centralized state management (#31)
- Standardized error response handling (#32)

### Fixed

- Improved domain error handling (#33)

## [0.2.3](https://github.com/cloudwalk/hermes-mcp) - 2025-03-12

### Added

- Enhanced SSE transport with graceful shutdown capabilities (#25)
- Improved SSE streaming with automatic reconnection handling (#25)

## [0.2.2](https://github.com/cloudwalk/hermes-mcp) - 2025-03-05

### Added

- Support for multiple concurrent client <> transport pairs (#24)
- Improved client resource management

## [0.2.1](https://github.com/cloudwalk/hermes-mcp) - 2025-02-28

### Added

- Support for custom base and SSE paths in HTTP/SSE client (#19)
- Enhanced configuration options for SSE endpoints

## [0.2.0](https://github.com/cloudwalk/hermes-mcp) - 2025-02-27

### Added

- Implemented HTTP/SSE transport (#7)
  - Support for server-sent events communication
  - HTTP client integration for MCP protocol
  - Streaming response handling

### Documentation

- Extensive guides and documentation improvements

## [0.1.0](https://github.com/cloudwalk/hermes-mcp) - 2025-02-26

### Added

- Implemented STDIO transport (#1) for MCP communication
  - Support for bidirectional communication via standard I/O
  - Automatic process monitoring and recovery
  - Environment variable handling for cross-platform support
  - Integration test utilities in Mix tasks

- Created stateful client interface (#6)
  - Robust GenServer implementation for MCP client
  - Automatic initialization and protocol handshake
  - Synchronous-feeling API over asynchronous transport
  - Support for all MCP operations (ping, resources, prompts, tools)
  - Proper error handling and logging
  - Capability negotiation and management

- Developed JSON-RPC message parsing (#5)
  - Schema-based validation of MCP messages
  - Support for requests, responses, notifications, and errors
  - Comprehensive test suite for message handling
  - Encoding/decoding functions with proper validation

- Established core architecture and client API
  - MCP protocol implementation following specification
  - Client struct for maintaining connection state
  - Request/response correlation with unique IDs
  - Initial transport abstraction layer

### Documentation

- Added detailed RFC document describing the library architecture
- Enhanced README with project overview and installation instructions
