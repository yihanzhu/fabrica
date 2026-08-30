import "portable-core-profile-graph-fixtures" as profile;
import "portable-core-stage-request-fixtures" as request;
import "portable-core-result-truth-fixtures" as result;

def metadata:
  {
    construction_base:"53f67eb337d30de8160643e3e6584cf9e8e7a7f3",
    generation_id:"g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386",
    parent_spec_blob:"c6511d96c1a5e6aed27ba2075b5add65c121f782",
    registry_oid:"5e113105777694a280166e71d31efd19752e9562",
    dependencies:[
      {slug:"portable-core-schema",g3_comment:5466181650,
       merge_commit:"d48ecdb908a395c5205260a662db7d9d3f4c1eb4",
       export_oid:"fd3924d414a7d620c2bf5de919a45c2599d572ec"},
      {slug:"portable-core-ingress",g3_comment:5468279667,
       merge_commit:"6ae9452848fd1bdec38aaef78efc842f5e938de3",
       export_oid:"e882b38b0106aac9142c667771f02e3107f8c52f"},
      {slug:"portable-core-profile-graph",g3_comment:5468723218,
       merge_commit:"fbe3850b94bfa153a169d5bb67348c1b312e3be6",
       export_oid:"48fd185eee7751eedf0ce381b77621e4d7cd1611"},
      {slug:"portable-core-stage-request",g3_comment:5469016860,
       merge_commit:"4ea04ee0ffb800668871b3b482557dd5a9041801",
       export_oid:"76c5d54437813a76502b46dc05215fb5b2c3f5bb"},
      {slug:"portable-core-result-facts",g3_comment:5469128966,
       merge_commit:"1c45dd3015bb22f13db41217d09a7d73a9b0617c",
       export_oid:"cfc3ed3b1c3d714412a6dffc85accaabb98cf3df"},
      {slug:"portable-core-result-truth",g3_comment:5469265117,
       merge_commit:"53f67eb337d30de8160643e3e6584cf9e8e7a7f3",
       export_oid:"3bdad8386cecd23adc7ee9960f0e1f4309626891"}
    ],
    review_rows:1,
    legacy_rows:21,
    aggregate_review_rows:34,
    aggregate_legacy_rows:279
  };

def manifest_docs: profile::manifest_docs;
def profile_doc($manifest_shas): profile::profile_doc($manifest_shas);
def resolved_profile_doc($profile; $profile_sha; $manifest_shas):
  profile::resolved_profile_doc($profile;$profile_sha;$manifest_shas);
def request_doc($role; $resolved_sha): request::request_doc($role;$resolved_sha);
def result_doc($request; $request_sha; $resolved; $resolved_sha):
  result::completed_result_doc($request;$request_sha;$resolved;$resolved_sha);
