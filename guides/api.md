# Hubs Server API
Reticulum includes a [GraphQL](https://graphql.org/) API that grants programmatic access to server resources. 

Note: This API is not yet stable, and may undergo breaking changes in future updates.

## Accessing the API
Hubs Cloud administrators can enable or disable the API by toggling `App Settings > Features > Public API Access` in the admin panel. 

Once enabled, the API can be accessed by sending HTTP `GET` and `POST` requests to `<your_hubs_cloud_host>/api/v2_alpha/`. 

## Authentication and Authorization
You must attach an API Access Token with each request.

To attach an API Access Token to a request, add an `HTTP` header named `Authorization` with value `Bearer: <your API token>`. 

### API Access Token Generation and Types
API Token can be generated and revoked though an interface located at `<your_hubs_cloud_host>/tokens`.

There are two types of API Access Tokens: 
- `:account` tokens act on behalf of a specific user
- `:app` tokens act on behalf of the Hubs Cloud itself

### Scopes
Each API Access Token specifies its `scopes`. Scopes allow a token to be used to perform specific actions.

| Scope | API Actions |
| --:            |         --- |      
| `read_rooms` | `myRooms`, `favoriteRooms`, `publicRooms` |
| `write_rooms` | `createRoom`, `updateRoom` |

Scopes, actions, and token types are expected to expand over time.

## Examples
Reticulum ships with [GraphiQL](https://github.com/graphql/graphiql/tree/main/packages/graphiql#graphiql), a graphical, interactive, in-browser GraphQL IDE that makes it easier to test and learn the API. It can be accessed by navigating to `<your_hubs_cloud_host>/api/v2_alpha/graphiql`. 

[This example workspace](../test/api/v2/graphiql-workspace-2023-02-17-11-24-40.json) demonstrates several queries and can be loaded into the GraphiQL interface. In the workspace, you will have to supply your own API access token(s) (see `TOKENUPDATEME` in file) and the host name of your deployment (see `HOSTUPDATEME` in file).

Requests can also be sent by
- an `HTTP` client library, 
- a command line tool like `curl`, 
- a GraphQL-specific client library, or
- any other tool that speaks `HTTP`. 

## What Can You Read and Write
GraphQL includes [handy introspection tools](https://graphql.org/learn/introspection/) which you can accessed through the IDE. The sample workspace above includes examples of introspection queries to learn about the parameters which can be manipulated through the API.

See [room_types.ex](../lib/ret_web/schema/room_types.ex) for full GraphQL Schema.
