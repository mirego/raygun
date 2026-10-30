# Raygun

Capture and send errors in your Elixir applications to Raygun for centralized
bug reporting.

## Install

Add the dependency to your mix.exs file.

```elixir
def deps do
  [{:raygun, github: "mirego/raygun"}]
end
```

## Configuration

Add the following entry to your config/config.exs file.

```elixir
config :raygun,
    api_key: "<INSERT YOUR API KEY HERE>"
```

You can *OPTIONALLY* add other configuration options as well. They will be sent
with every error.
* tags: list of metadata strings
* url: a reference URL
* client_name: the name of the application as you want it to appear in Raygun
* client_version: the version of the application as you want it to appear in Raygun
* before_send: a {module, function} tuple that allows you to modify or filter exceptions before they're sent to Raygun

```elixir
config :raygun,
    api_key: "<INSERT YOUR API KEY HERE>",
    tags: ["tag1", "tag2"],
    url: "http://docs.myapp.example.com",
    client_name: "MyApp",
    client_version: "2.3.4",
    before_send: {MyApp.RaygunFilter, :filter_exception}
```

### before_send Configuration

The `before_send` callback allows you to modify exceptions before they are sent to Raygun, or prevent them from being sent entirely. This is useful for:

- Filtering out sensitive information
- Adding additional context
- Preventing certain types of exceptions from being reported

The callback function should accept an exception and return either:
- `{:ok, exception}` - to send the (potentially modified) exception
- `{:error, reason}` - to prevent the exception from being sent

```elixir
defmodule MyApp.RaygunFilter do
  def filter_exception(%ArgumentError{} = exception) do
    {:error, :filtered}
  end
end
```

If you use a Plug, the version (client_version above) should be auto detected for you.

## Usage

There are three different ways you can use Raygun. All three ways may be combined,
but you _might_ send the same message multiple times if you do that.

### Via Plug in Phoenix

Add the plug to your router:

```elixir
defmodule YourApp.Router do
  use Phoenix.Router
  use Raygun.Plug

  # ...
end
```

You can also provide a function that takes a Plug.Conn and returns a map with
information about the logged in user.

```elixir
defmodule YourApp.Router do
  use Phoenix.Router
  use Raygun.Plug, user: fn(conn) ->
    %{
      identifier: "<user id>",
      isAnonymous: false, # false if logged in, true if not logged in
      email: "email@example.com",
      fullName: "John Doe",
      firstName: "John",
      uuid: "<uuid>"
    }
  end

  # ...
end
```

### Via the Logger

Any error logged with automatically be sent to Raygun.

Configure the Logger to use the Raygun backend. You can do this programmatically

  ```elixir
  Logger.add_backend(Raygun.Logger)
  ```

or via configuration by adding Raygun as a backend in config/config.exs:

  ```elixir
  config :logger,
    backends: [:console, Raygun.Logger]
  ```

Any messages logged at :error level will be automatically sent to Raygun.

If you would like messages to be associated with a system user then add the
following configuration to config/config.exs:

  ```elixir
  config :raygun,
      system_user: %{
        			identifier: "myuserid",
        			isAnonymous: true,
        			email: "myuserid@example.com",
        			fullName: "Jane Doe",
        			firstName: "Jane",
        			uuid: "b07eb66c-9055-4847-a173-881b77cdc83e"
      		  }
  ```

### Any Elixir code

Send a string message to Raygun:

```elixir
Raygun.report_message "Oh noes."
```

Report an exception programmatically with its stacktrace. Use `__STACKTRACE__`
inside the `rescue` clause.

```elixir
try do
  :foo = :bar
rescue
  exception -> Raygun.report_stacktrace(__STACKTRACE__, exception)
end
```

You can pass custom context as an optional final keyword list. It will appear
as 'userCustomData' under the custom tab in Raygun's web interface.

```elixir
try do
  :foo = :bar
rescue
  exception ->
    Raygun.report_stacktrace(__STACKTRACE__, exception, env: Mix.env())
end
```

## Isolation du backend Logger

Le backend `Raygun.Logger` est **asynchrone**. Il sélectionne les erreurs locales
et tente une admission ETS sans appel HTTP, callback utilisateur, encodage JSON,
appel synchrone au dispatcher ou message envoyé au dispatcher. Le retour de
Logger ne confirme donc **pas** la réception par Raygun.

L'application OTP `:raygun` démarre automatiquement avec les dépendances Mix.
Pour un démarrage manuel, appeler `Application.ensure_all_started(:raygun)`
**avant** `Logger.add_backend(Raygun.Logger)`. Une configuration statique du
backend dans `:logger` peut perdre les premiers événements avant ce démarrage.
Sans application Raygun, Logger continue et abandonne les rapports.

```elixir
config :raygun,
  reporter: [
    capacity: 100,
    concurrency: 2,
    max_bytes: 262_144,
    timeout: 10_000,
    poll_interval: 10,
    rate_limit: 100
  ],
  httpoison_opts: [timeout: 2_000, recv_timeout: 5_000]
```

Les options `reporter` sont des entiers strictement positifs, lus au démarrage :

| Option | Garantie |
| --- | --- |
| `capacity` | Nombre total de rapports admis, en attente **et** en cours. Les nouveaux rapports sont rejetés à saturation. |
| `concurrency` | Nombre maximal de workers, inférieur ou égal à `capacity`. |
| `max_bytes` | Limite de l'événement brut (message et métadonnées, via `:erlang.external_size/1`) avant copie dans ETS, puis du JSON encodé avant HTTP. |
| `timeout` | Échéance en millisecondes par worker : callback `before_send`, formatage, encodage et transport inclus. L'attente d'une place de worker n'est pas incluse. |
| `poll_interval` | Intervalle de recherche des événements admis, en millisecondes. Aucun message par événement n'est nécessaire. |
| `rate_limit` | Nombre maximal de tentatives d'admission par fenêtre fixe de 1 seconde, après exclusion des événements internes et trop gros. |

Les valeurs par défaut limitent la rétention brute à environ 25 Mio, plus les
copies temporaires des deux workers et les données encodées. Deux workers
réduisent la charge réseau; une échéance de 10 secondes permet de dépasser les
délais HTTP normaux sans bloquer les rapports suivants. La file ETS est un
ensemble de places fixes, pas une mailbox ni une file FIFO : l'ordre de livraison
n'est pas garanti. La publication d'une place est atomique; une place en cours
reste occupée jusqu'au `:DOWN` du worker, même après annulation. Le dispatcher
possède la table : sa disparition détruit l'ancienne génération. La supervision
`rest_for_one` arrête les anciens workers avant de reprendre le traitement.

**Limites mémoire :** l'événement a déjà été créé et copié dans Logger avant
l'admission. Le calcul de sa taille parcourt le terme brut. La limite n'est pas
une limite de heap pour un callback arbitraire : le formatage, le callback et
l'encodage peuvent allouer des données temporaires avant leur vérification.
Les métadonnées d'origine sont conservées dans l'événement admis et appliquées
au worker; elles ne sont pas ajoutées au payload existant. Le format existant
n'inclut pas de PID, donc il n'est pas remplacé par celui du worker.

Les workers portent la métadonnée `raygun_reporting: true`. Le backend ignore
leurs logs. Les processus internes des dépendances ne conservent pas
nécessairement cette métadonnée; la limite globale complète donc cette
protection. Elle borne le débit mais ne garantit pas l'absence de tout rapport
secondaire non marqué. Une fenêtre fixe peut admettre deux fois la limite à sa
frontière. Les rejets et échecs ne produisent pas de log par rapport. Aucun retry
n'est effectué.

`Raygun.Reporter.stats/0` expose localement des compteurs (`accepted`, `full`,
`oversized`, `internal`, `rate_limited`, `completed`, `failed`, `timed_out`) et
`pending` (en attente et en cours). Ces valeurs sont réinitialisées au redémarrage;
un timeout compte aussi comme échec. Elles n'exposent aucun payload, secret ou
identifiant utilisateur. Aucun callback de télémétrie n'est exécuté dans Logger.

L'arrêt n'effectue aucun flush réseau. Les workers sont arrêtés immédiatement;
les rapports en mémoire sont perdus. Hackney 4.8.5 surveille le propriétaire des
connexions HTTP/1.1 et ferme celles en cours à sa disparition. Le test local TCP
vérifie ce nettoyage pendant une réception bloquée avec le vrai HTTPoison,
avec le pool par défaut. Cela ne prouve pas le nettoyage de tous les chemins
(proxy, HTTP/2 partagé ou disparition de SSL).

### API synchrones et transport

`report_message`, `report_stacktrace`, `report_exception` et `report_plug` restent
**synchrones**. Leurs retours `:ok` correspondent toujours à HTTP 202, pas à une
acceptation locale. Les retours du callback d'exclusion restent inchangés.
HTTP 400 retourne `{:error, :bad_message}`, HTTP 403 retourne
`{:error, :invalid_api_key}`; les erreurs de transport, sorties, exceptions de
transport et autres réponses retournent `{:error, :unexpected}`.

Les options utilisateur `httpoison_opts` remplacent les valeurs par défaut de
connexion (`timeout: 2_000`) et réception (`recv_timeout: 5_000`), avec une fusion
au premier niveau. Les options imbriquées, dont `hackney`, restent intactes.
Un utilisateur peut donc choisir des délais plus longs ou infinis : l'échéance
globale protège seulement le pipeline asynchrone, **pas** les appels publics
directs ni leurs callbacks. Le transport par défaut reste HTTPoison, vers
`https://api.raygun.io/entries`, sans modification des options TLS.

Pour les tests sans Internet, `config :raygun, transport: MonTransport` accepte
un module qui implémente `Raygun.Transport.post/4`. Aucun endpoint de production
n'est utilisé par les tests. Exécuter `mix test` et
`mix format --check-formatted` avec Elixir 1.18 / OTP 27.

Cette isolation ne corrige pas la disparition des processus SSL et ne remplace
pas une investigation de sa cause. Aucun test destructif SSL n'est requis.

## License

[LICENSE](LICENSE)
