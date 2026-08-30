import "portable-core-result-facts-fixtures" as facts;

def metadata:
  {
    construction_base:"1c45dd3015bb22f13db41217d09a7d73a9b0617c",
    generation_id:"g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386",
    parent_spec_blob:"c6511d96c1a5e6aed27ba2075b5add65c121f782",
    schema_g3_comment:5466181650,
    schema_export_oid:"fd3924d414a7d620c2bf5de919a45c2599d572ec",
    ingress_g3_comment:5468279667,
    ingress_export_oid:"e882b38b0106aac9142c667771f02e3107f8c52f",
    profile_g3_comment:5468723218,
    profile_export_oid:"48fd185eee7751eedf0ce381b77621e4d7cd1611",
    stage_request_g3_comment:5469016860,
    stage_request_export_oid:"76c5d54437813a76502b46dc05215fb5b2c3f5bb",
    result_facts_g3_comment:5469128966,
    result_facts_merge_commit:"1c45dd3015bb22f13db41217d09a7d73a9b0617c",
    result_facts_export_oid:"cfc3ed3b1c3d714412a6dffc85accaabb98cf3df",
    registry_oid:"5e113105777694a280166e71d31efd19752e9562",
    frozen_source_head:"ab4a7082f02e67b5748c5c54b9214f37d222f53f",
    frozen_test_blob:"8a9921d3763e3fcfa103037b021dd6c95bdcad61",
    mapping_sha256:"2e88fee2b0f59a858e6ac0f2ff51d9fa48e8491e52294c06beeebbbdf386888d",
    review_rows:8,
    legacy_rows:48,
    owned_rules:41,
    direct_cases:125,
    command_to_rule_cells:2,
    forced_routes:2,
    guard_cases:15
  };

def sha($character): $character * 64;

def content($id; $media_type; $character):
  {content_id:$id,media_type:$media_type,sha256:sha($character)};

def reason($id): {reason_id:$id};

def evidence($id; $kind; $verdict):
  {
    evidence_id:$id,
    kind:$kind,
    verdict:$verdict,
    proof_ref:content("proof." + $id;"application/json";"b")
  };

def output($id; $media_type; $character):
  {output_id:$id,ref:content("output." + $id;$media_type;$character)};

def unavailable($id): {state:"unavailable",reason_id:$id};
def absent: {state:"absent"};
def present($value): {state:"present",value:$value};

def completed_result_doc($request; $request_sha; $resolved; $resolved_sha):
  facts::result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.evidence = ($request.body.required_evidence_kinds |
    map(evidence("evidence." + .;.;"passed")));

def skipped_result_doc($request; $request_sha; $resolved; $resolved_sha):
  completed_result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.status="skipped" |
  .body.reason=reason("stage.skipped") |
  .body.outputs=[] |
  .body.diagnostics=[] |
  .body.evidence=[] |
  del(.body.outcome,.body.execution,.body.started_at,.body.finished_at);

def stale_result_doc($request; $request_sha; $resolved; $resolved_sha):
  skipped_result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.status="stale" |
  .body.reason=reason("stage.stale") |
  .body.stale_observations=[{
    selector:{kind:"environment"},
    observed:present(
      $request.body.environment_ref + {fingerprint_sha256:sha("0")})
  }];

def blocked_result_doc($request; $request_sha; $resolved; $resolved_sha):
  skipped_result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.status="blocked" |
  .body.reason=reason("stage.blocked") |
  .body.diagnostics=[content("diagnostic.blocked";"text/plain";"c")];

def failed_result_doc($request; $request_sha; $resolved; $resolved_sha):
  completed_result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.status="failed" |
  .body.outcome={
    family:(if $request.body.operation.role == "producer" then "change" else "check" end),
    value:"inconclusive"
  } |
  .body.reason=reason("stage.failed") |
  .body.outputs=[] |
  .body.diagnostics=[content("diagnostic.failed";"text/plain";"d")] |
  .body.evidence |= map(.verdict="failed");

def cancelled_result_doc($request; $request_sha; $resolved; $resolved_sha):
  failed_result_doc($request;$request_sha;$resolved;$resolved_sha) |
  .body.status="cancelled" |
  .body.reason=reason("stage.cancelled") |
  .body.diagnostics=[];
