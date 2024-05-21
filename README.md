# Reticulum
Note: **Due to our small team size, we don't support setting up Reticulum locally due to restrictions on developer credentials. Although relatively difficult and new territory, you're welcome to set up this up yourself. In addition to running Reticulum locally, you'll need to also run [Hubs](https://github.com/mozilla/hubs) and [Dialog](https://github.com/mozilla/dialog) locally because the developer Dialog server is locked down and your local Reticulum will not connect properly)**

Reference [this discussion thread](https://github.com/mozilla/hubs/discussions/3323) for more information.

A hybrid game networking and web API server, focused on Social Mixed Reality.

## Development

### 1. Install Prerequisite Packages:

#### PostgreSQL (recommended version 11.x):

Linux:

On Ubuntu, you can use

```
apt install postgresql
```

Otherwise, consult your package manager of choice for other Linux distributions

Windows: https://www.postgresql.org/download/windows/

Windows WSL: https://github.com/michaeltreat/Windows-Subsystem-For-Linux-Setup-Guide/blob/master/readmes/installs/PostgreSQL.md

#### Erlang (v23.3) + Elixir (v1.14) + Phoenix

https://elixir-lang.org/install.html

Note: On Linux, you may also have to install the erlang-src package for your distribution in order to compile dependencies successfully.

https://hexdocs.pm/phoenix/installation.html

#### Ansible

https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html

### 2. Setup Reticulum:

Run the following commands at the root of the reticulum directory:

1. `mix deps.get`
2. `mix ecto.create`
   - If step 2 fails, you may need to change the password for the `postgres` role to match the password configured `dev.exs`.
   - From within the `psql` shell, enter `ALTER USER postgres WITH PASSWORD 'postgres';`
   - If you receive an error that the `ret_dev` database does not exist, (using psql again) enter `create database ret_dev;`
   - If you receive an error that says `ERROR 42501 (insufficient_privilege) permission denied to create role`, (using psql) enter `alter user postgres createrole;`
3. From the project directory `mkdir -p storage/dev`

### 3. Start Reticulum

Run `scripts/run.sh` if you have the hubs secret repo cloned. Otherwise `iex -S mix phx.server`

## Run Hubs Against a Local Reticulum Instance

### 1. Setup the `hubs.local` hostname

When running the full stack for Hubs (which includes Reticulum) locally it is necessary to add a `hosts` entry pointing `hubs.local` to your local server's IP.
This will allow the CSP checks to pass that are served up by Reticulum so you can test the whole app. Note that you must also load hubs.local over https.

On MacOS or Linux:

```bash
nano /etc/hosts
```

From there, add a host alias

Example:

```bash
127.0.0.1   hubs.local
127.0.0.1   hubs-proxy.local
```

### 2. Setting up the Hubs Repository

Clone the Hubs repository and install the npm dependencies.

```bash
git clone https://github.com/mozilla/hubs.git
cd hubs
npm ci
```

### 3. Start the Hubs Webpack Dev Server

Because we are running Hubs against the local Reticulum client you'll need to use the `npm run local` command in the root of the `hubs` folder. This will start the development server on port 8080, but configure it to be accessed through Reticulum on port 4000.

### 4. Navigate To The Client Page

Once both the Hubs Webpack Dev Server and Reticulum server are both running you can navigate to the client by opening up:

https://hubs.local:4000?skipadmin

> The `skipadmin` is a temporary measure to bypass being redirected to the admin panel. Once you have logged in you will no longer need this.

### 5. Logging In

To log into Hubs we use magic links that are sent to your email. When you are running Reticulum locally we do not send those emails. Instead, you'll find the contents of that email in the Reticulum console output.

With the Hubs landing page open click the Sign In button at the top of the page. Enter an email address and click send.

Go to the reticulum terminal session and find a url that looks like https://hubs.local:4000/?auth_origin=hubs&auth_payload=XXXXX&auth_token=XXXX

Navigate to that url in your browser to finish signing in.

### 6. Creating an Admin User

After you've started Reticulum for the first time you'll likely want to create an admin user. Assuming you want to make the first account the admin, this can be done in the iex console:
1) Open the iex console. From the reticulum folder run:
```
iex -S mix
```
2) Then run the following code:
```
Ret.Account |> Ret.Repo.all() |> Enum.at(0) |> Ecto.Changeset.change(is_admin: true) |> Ret.Repo.update!()
```

Make sure to run the Maybe try iex -S mix where the reticulum mix.exs file is.

### 7. Enabling Room Features

Rooms are created with restricted permissions by default, which means you can't spawn media objects. You can change this setting in the admin panel, or run the following code in the iex console:
1) Open the iex console. From the reticulum folder run:
```
iex -S mix
```
2) Then run the following code:
```
Ret.AppConfig.set_config_value("features|permissive_rooms", true)
```

### 8. Start the Admin Panel server in local development mode

When running locally, you will need to also run the admin panel, which routes to hubs.local:8989
Using a separate terminal instance, navigate to the `hubs/admin` folder and use:

```
npm run local
```

You can now navigate to https://hubs.local:4000/admin to access the admin control panel

## Run Spoke Against a Local Reticulum Instance

1. Follow the steps above to setup Hubs
2. Clone and start spoke by running `./scripts/run_local_reticulum.sh` in the root of the spoke project
3. Navigate to https://hubs.local:4000/spoke

## Run Reticulum against a local Dialog instance

1. Update the Janus host in `dev.exs`:

```
dev_janus_host = "hubs.local"
```

2. Update the Janus port in `dev.exs`:

```
config :ret, Ret.JanusLoadStatus, default_janus_host: dev_janus_host, janus_port: 4443
```

3. Add the Dialog meta endpoint to the CSP rules in `add_csp.ex`:

```
default_janus_csp_rule =
   if default_janus_host,
      do: "wss://#{default_janus_host}:#{janus_port} https://#{default_janus_host}:#{janus_port} https://#{default_janus_host}:#{janus_port}/meta",
      else: ""
```

4. Edit the Dialog configuration file _turnserver.conf_ and update the PostgreSQL database connection string to use the _coturn_ schema from the Reticulum database:

```
   psql-userdb="host=hubs.local dbname=ret_dev user=postgres password=postgres options='-c search_path=coturn' connect_timeout=30"
```
