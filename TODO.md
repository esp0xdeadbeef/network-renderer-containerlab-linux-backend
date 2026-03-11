# TODO — Remove Hardcoded Tenant / Zone Names

Renderer must not infer zones from interface or node name strings.

* Remove substring-based zone detection (`admin`, `client`, `mgmt`, etc.).
* Zones must be derived from solver model semantics:

  * `ownership.endpoints[].tenant`
  * `provider_zone_map`
  * interface `kind`
  * `_s88_links` topology.
* All renderer modules must consume a deterministic `zone → interface` map.
* Zone resolution must be centralized in a single renderer helper.
* Renderer must hard fail if zones cannot be resolved from the model.
* Renderer must never depend on naming conventions.

