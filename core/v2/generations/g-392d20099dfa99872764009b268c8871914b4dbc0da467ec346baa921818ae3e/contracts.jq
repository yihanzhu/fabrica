import "schema" as schema;
import "profile_graph" as profile_graph;
import "stage_request" as stage_request;
import "result_facts" as result_facts;
import "result_truth" as result_truth;

def pair_shape_ok:
  schema::exact_fields(["content","sha256"];[]) and
  (.content | type == "object") and
  (.sha256 | schema::sha256_ok);

def route_shape_ok:
  schema::exact_fields(["mode","docs"];[]) and
  (.docs | type == "array") and
  all(.docs[]; pair_shape_ok) and
  (if .mode == "document" then
     (.docs | length) == 1
   elif .mode == "profile-set" then
     (.docs | length) >= 3 and (.docs | length) <= 10
   elif .mode == "stage-run" then
     (.docs | length) == 3
   else false
   end);

def document_shape_ok:
  if .kind == "adapter_manifest" or .kind == "profile" or
     .kind == "resolved_profile" then
    profile_graph::document_shape_ok
  elif .kind == "stage_request" then
    stage_request::document_shape_ok
  elif .kind == "stage_result" then
    result_truth::document_shape_ok
  else false
  end;

def document_self_ok:
  if .kind == "adapter_manifest" or .kind == "profile" or
     .kind == "resolved_profile" then
    profile_graph::document_self_ok
  elif .kind == "stage_request" then
    stage_request::document_self_ok
  elif .kind == "stage_result" then
    result_facts::document_shape_ok and result_truth::document_self_ok
  else false
  end;

def parsed_limits_ok:
  all(.docs[].content; schema::parsed_limits_ok);

def shapes_ok:
  route_shape_ok and all(.docs[].content; document_shape_ok);

def refs_ok:
  .docs as $docs |
  if .mode == "document" then true
  elif .mode == "profile-set" then
    profile_graph::profile_set_refs_ok($docs[0];$docs[1];$docs[2:])
  elif .mode == "stage-run" then
    stage_request::stage_request_resolved_ref_ok($docs[0];$docs[1]) and
    result_truth::refs_relation_ok($docs[0];$docs[1];$docs[2].content.body)
  else false
  end;

def relations_ok:
  .docs as $docs |
  if .mode == "document" then
    ($docs[0].content | document_self_ok)
  elif .mode == "profile-set" then
    all($docs[].content; document_self_ok) and
    profile_graph::profile_set_graph_ok($docs[0];$docs[1];$docs[2:])
  elif .mode == "stage-run" then
    all($docs[].content; document_self_ok) and
    stage_request::stage_request_resolved_relation_ok(
      $docs[0].content.body;$docs[1].content.body) and
    result_truth::stage_result_relation_ok(
      $docs[0];$docs[1];$docs[2].content.body)
  else false
  end;

if (parsed_limits_ok | not) then "E_LIMIT"
elif (shapes_ok | not) then "E_SHAPE"
elif (refs_ok | not) then "E_REF"
elif (relations_ok | not) then "E_RELATION"
else empty
end
