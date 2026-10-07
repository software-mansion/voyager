# Changelog

## 0.2.0 (2026-10-07)

#### Features

* Process list page in [#208](https://github.com/software-mansion/voyager/pull/208)
* Process info page in [#233](https://github.com/software-mansion/voyager/pull/233)
* ETS table list page in [#216](https://github.com/software-mansion/voyager/pull/216)
* ETS table contents view in [#236](https://github.com/software-mansion/voyager/pull/236)
* ETS match-spec search in [#225](https://github.com/software-mansion/voyager/pull/225)
* Paged key lookup for bag and duplicate_bag ETS tables in [#239](https://github.com/software-mansion/voyager/pull/239), [#263](https://github.com/software-mansion/voyager/pull/263)
* Look up any non-truncated key from the ETS contents view in [#276](https://github.com/software-mansion/voyager/pull/276)
* Term inspector in [#221](https://github.com/software-mansion/voyager/pull/221)
* MCP tools for processes in [#230](https://github.com/software-mansion/voyager/pull/230)
* MCP tools for ETS tables in [#231](https://github.com/software-mansion/voyager/pull/231)
* In-app updates: the desktop app checks for a new release on startup and can install it, with an Updates card in Settings in [#251](https://github.com/software-mansion/voyager/pull/251)
* IPv6 support when connecting to nodes, directly and over SSH in [#159](https://github.com/software-mansion/voyager/pull/159)
* Setting to show the connected node's PIDs in local `<0.X.Y>` format in [#184](https://github.com/software-mansion/voyager/pull/184)
* Help tooltips with Erlang docs links on process and ETS panels, and a connecting-to-a-node guide in [#245](https://github.com/software-mansion/voyager/pull/245)

#### Enhancements

* Jump to linked processes from the supervision tree details panel, with a Back button through the jump history in [#277](https://github.com/software-mansion/voyager/pull/277)
* Default macOS menu (Hide, Minimize, Fullscreen), View → Zoom In (Cmd+=) / Zoom Out (Cmd+-) / Actual Size, Help → Report an Issue…, and Cmd/Ctrl+B to toggle the sidebar in [#238](https://github.com/software-mansion/voyager/pull/238), [#255](https://github.com/software-mansion/voyager/pull/255)
* Install the `voyager_agent` helper module on node connect (inspected node needs OTP 27+) in [#193](https://github.com/software-mansion/voyager/pull/193), [#223](https://github.com/software-mansion/voyager/pull/223)
* Version the remote agent so different Voyager versions can inspect the same node in [#273](https://github.com/software-mansion/voyager/pull/273)
* Rate limit remote node introspection calls in [#201](https://github.com/software-mansion/voyager/pull/201)
* Rate limit process fetches in the supervision tree details panel in [#260](https://github.com/software-mansion/voyager/pull/260)
* Show a notice instead of rendering supervision trees above 2,000 elements in [#258](https://github.com/software-mansion/voyager/pull/258)
* Start distribution without a listening port or EPMD registration in [#218](https://github.com/software-mansion/voyager/pull/218)
* More specific node connection error messages in [#177](https://github.com/software-mansion/voyager/pull/177)
* Only one app instance can run at a time in [#169](https://github.com/software-mansion/voyager/pull/169)
* Used-percentage column in System limits in [#261](https://github.com/software-mansion/voyager/pull/261)
* Remember the auto-refresh interval across reloads in [#197](https://github.com/software-mansion/voyager/pull/197)
* Keep the selected connection type (Direct / SSH) in the URL in [#183](https://github.com/software-mansion/voyager/pull/183)
* Highlight the key in ETS record rows in [#270](https://github.com/software-mansion/voyager/pull/270)
* Select dropdowns styled to match the app in [#259](https://github.com/software-mansion/voyager/pull/259)
* Sidebar tooltips in compact mode in [#166](https://github.com/software-mansion/voyager/pull/166)
* Feedback link in the sidebar in [#160](https://github.com/software-mansion/voyager/pull/160)
* Copy buttons confirm with an icon change in [#161](https://github.com/software-mansion/voyager/pull/161)
* Better tooltips on the connect page in [#158](https://github.com/software-mansion/voyager/pull/158)
* Supervision tree icon rotated to match the tree's left-to-right layout in [#271](https://github.com/software-mansion/voyager/pull/271)

#### Bug fixes

* Generate a random distribution cookie per launch in [#205](https://github.com/software-mansion/voyager/pull/205)
* Bind the packaged app's endpoint to loopback instead of all interfaces in [#190](https://github.com/software-mansion/voyager/pull/190)
* Protect the MCP HTTP endpoint against DNS rebinding: reject non-loopback `Origin` and `Host` headers and always bind to `127.0.0.1` in [#247](https://github.com/software-mansion/voyager/pull/247), [#250](https://github.com/software-mansion/voyager/pull/250)
* Pin the host part of Voyager's own node name to `127.0.0.1` (long names) or `localhost` (short names) in [#149](https://github.com/software-mansion/voyager/pull/149)
* Fix SSH agent authentication option in [#222](https://github.com/software-mansion/voyager/pull/222)
* Persist the MCP enabled setting in the database in [#176](https://github.com/software-mansion/voyager/pull/176)
* Fix MCP telemetry in [#152](https://github.com/software-mansion/voyager/pull/152)
* Follow GNOME theme changes in Auto mode on Linux in [#281](https://github.com/software-mansion/voyager/pull/281)
* Fix app icon on older macOS versions in [#165](https://github.com/software-mansion/voyager/pull/165)
* Update the connection-type tooltip after disconnecting from a node in [#148](https://github.com/software-mansion/voyager/pull/148)
* Fix the ETS lookup sidebar button overflowing the window in [#272](https://github.com/software-mansion/voyager/pull/272)
* Fix the multiselect dropdown covering the sidebar in [#286](https://github.com/software-mansion/voyager/pull/286)
* Hide spinner arrows on number inputs in [#287](https://github.com/software-mansion/voyager/pull/287)
* Hide the WebKit caps lock indicator in password fields in [#265](https://github.com/software-mansion/voyager/pull/265)
* Dim the show-password toggle while connecting in [#199](https://github.com/software-mansion/voyager/pull/199)

## 0.2.0-rc.1 (2026-10-07)

#### Features

* In-app updates: the desktop app checks for a new release on startup and can install it, with an Updates card in Settings in [#251](https://github.com/software-mansion/voyager/pull/251)
* Paged key lookup for bag and duplicate_bag ETS tables in [#239](https://github.com/software-mansion/voyager/pull/239), [#263](https://github.com/software-mansion/voyager/pull/263)
* Look up any non-truncated key from the ETS contents view in [#276](https://github.com/software-mansion/voyager/pull/276)
* IPv6 support when connecting to nodes, directly and over SSH in [#159](https://github.com/software-mansion/voyager/pull/159)
* Setting to show the connected node's PIDs in local `<0.X.Y>` format in [#184](https://github.com/software-mansion/voyager/pull/184)
* Help tooltips with Erlang docs links on process and ETS panels, and a connecting-to-a-node guide in [#245](https://github.com/software-mansion/voyager/pull/245)

#### Enhancements

* Default macOS menu (Hide, Minimize, Fullscreen), View → Zoom In / Zoom Out / Actual Size, Help → Report an Issue…, and Cmd/Ctrl+B to toggle the sidebar in [#255](https://github.com/software-mansion/voyager/pull/255)
* More specific node connection error messages in [#177](https://github.com/software-mansion/voyager/pull/177)
* Version the remote agent so different Voyager versions can inspect the same node in [#273](https://github.com/software-mansion/voyager/pull/273)
* Show a notice instead of rendering supervision trees above 2,000 elements in [#258](https://github.com/software-mansion/voyager/pull/258)
* Rate limit process fetches in the supervision tree details panel in [#260](https://github.com/software-mansion/voyager/pull/260)
* Used-percentage column in System limits in [#261](https://github.com/software-mansion/voyager/pull/261)
* Remember the auto-refresh interval across reloads in [#197](https://github.com/software-mansion/voyager/pull/197)
* Keep the selected connection type (Direct / SSH) in the URL in [#183](https://github.com/software-mansion/voyager/pull/183)
* Highlight the key in ETS record rows in [#270](https://github.com/software-mansion/voyager/pull/270)
* Select dropdowns styled to match the app in [#259](https://github.com/software-mansion/voyager/pull/259)
* Supervision tree icon rotated to match the tree's left-to-right layout in [#271](https://github.com/software-mansion/voyager/pull/271)

#### Bug fixes

* Protect the MCP HTTP endpoint against DNS rebinding: reject non-loopback `Origin` and `Host` headers and always bind to `127.0.0.1` in [#247](https://github.com/software-mansion/voyager/pull/247), [#250](https://github.com/software-mansion/voyager/pull/250)
* Follow GNOME theme changes in Auto mode on Linux in [#281](https://github.com/software-mansion/voyager/pull/281)
* Fix the ETS lookup sidebar button overflowing the window in [#272](https://github.com/software-mansion/voyager/pull/272)
* Fix the multiselect dropdown covering the sidebar in [#286](https://github.com/software-mansion/voyager/pull/286)
* Hide spinner arrows on number inputs in [#287](https://github.com/software-mansion/voyager/pull/287)
* Hide the WebKit caps lock indicator in password fields in [#265](https://github.com/software-mansion/voyager/pull/265)
* Dim the show-password toggle while connecting in [#199](https://github.com/software-mansion/voyager/pull/199)

## 0.2.0-rc.0 (2026-09-10)

#### Features

* Process list page in [#208](https://github.com/software-mansion/voyager/pull/208)
* Process info page in [#233](https://github.com/software-mansion/voyager/pull/233)
* ETS table list page in [#216](https://github.com/software-mansion/voyager/pull/216)
* ETS table contents view in [#236](https://github.com/software-mansion/voyager/pull/236)
* ETS match-spec search in [#225](https://github.com/software-mansion/voyager/pull/225)
* Term inspector in [#221](https://github.com/software-mansion/voyager/pull/221)
* MCP tools for processes in [#230](https://github.com/software-mansion/voyager/pull/230)
* MCP tools for ETS tables in [#231](https://github.com/software-mansion/voyager/pull/231)

#### Enhancements

* Zoom In / Zoom Out menu actions (Cmd+= / Cmd+-) in the macOS app in [#238](https://github.com/software-mansion/voyager/pull/238)
* Install the `voyager_agent` helper module on node connect (inspected node needs OTP 27+) in [#193](https://github.com/software-mansion/voyager/pull/193), [#223](https://github.com/software-mansion/voyager/pull/223)
* Rate limit remote node introspection calls in [#201](https://github.com/software-mansion/voyager/pull/201)
* Start distribution without a listening port or EPMD registration in [#218](https://github.com/software-mansion/voyager/pull/218)
* Only one app instance can run at a time in [#169](https://github.com/software-mansion/voyager/pull/169)
* Sidebar tooltips in compact mode in [#166](https://github.com/software-mansion/voyager/pull/166)
* Feedback link in the sidebar in [#160](https://github.com/software-mansion/voyager/pull/160)
* Copy buttons confirm with an icon change in [#161](https://github.com/software-mansion/voyager/pull/161)
* Better tooltips on the connect page in [#158](https://github.com/software-mansion/voyager/pull/158)

#### Bug fixes

* Generate a random distribution cookie per launch in [#205](https://github.com/software-mansion/voyager/pull/205)
* Bind the packaged app's endpoint to loopback instead of all interfaces in [#190](https://github.com/software-mansion/voyager/pull/190)
* Fix SSH agent authentication option in [#222](https://github.com/software-mansion/voyager/pull/222)
* Persist the MCP enabled setting in the database in [#176](https://github.com/software-mansion/voyager/pull/176)
* Fix app icon on older macOS versions in [#165](https://github.com/software-mansion/voyager/pull/165)
* Fix MCP telemetry in [#152](https://github.com/software-mansion/voyager/pull/152)

## 0.1.0 (2026-08-04)

Closed Alpha release
