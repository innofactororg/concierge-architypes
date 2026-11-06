//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/tags.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// `createdOn` is owned by the infrastructure code, per resource: minted once, when the resource
// is first created, and carried unchanged on every later deployment.
//
// Why not `param createdOn string = utcNow()` alone: `utcNow()` is evaluated on every deployment,
// so the tag would record the LAST deployment, not the creation. Why not leave it to the Append
// policy: a policy evaluates the incoming request, and every deployment PUTs the resource with a
// tag set that has no `createdOn`, so the policy stamps the deployment time as well.
//
// How it is preserved: the pipeline reads the `createdOn` tag of what already exists in the
// subscription before the template is compiled and hands it to the parameter file through the
// EXISTING_TAGS environment variable, as an object keyed by lower-cased resource id. A resource
// that is in the object keeps its value; only a resource that is not there yet takes `now`.
// The parameter file reads the variable WITHOUT a default, so a pipeline that does not provide it
// fails the build instead of silently re-stamping every resource.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@export()
@description('The base tags plus a createdOn that is the existing value when the resource already carries one, otherwise `now`.')
func tagsFor(baseTags object, existingTags object, now string, resourceId string) object =>
  union(baseTags, { createdOn: existingTags[?toLower(resourceId)].?createdOn ?? now })
