// IMPORTS ---------------------------------------------------------------------

import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import lustre/element.{type Element}
import simplifile
import temporary

// MAIN ------------------------------------------------------------------------

/// Initialise a new configuration for the static site generator. If you pass a
/// relative path it will be resolved relative to the current working directory,
/// _not_ the directory of the Gleam file.
///
pub fn new(
  out_dir: String,
) -> Config(NoStaticRoutes, NoStaticDir, UseDirectRoutes) {
  Config(
    out_dir: out_dir,
    static_dir: None,
    static_assets: dict.new(),
    routes: [],
    use_index_routes: False,
  )
}

/// Generate the static site. This will delete the output directory if it already
/// exists and then generate all of the routes configured. If a static assets
/// directory has been configured, its contents will be recursively copied into
/// the output directory **before** any routes are generated.
///
pub fn build(
  config: Config(HasStaticRoutes, has_static_dir, use_index_routes),
) -> Result(Nil, BuildError) {
  case do_build(config) {
    Ok(result) -> result
    Error(error) -> Error(CannotCreateTempDirectory(error))
  }
}

/// Generate the static site. This will delete the output directory if it already
/// exists and then generate all of the routes configured. If a static assets
/// directory has been configured, its contents will be recursively copied into
/// the output directory **before** any routes are generated.
///
fn do_build(
  config: Config(HasStaticRoutes, has_static_dir, use_index_routes),
) -> Result(Result(Nil, BuildError), simplifile.FileError) {
  let Config(out_dir, static_dir, static_assets, routes, use_index_routes) =
    config
  let out_dir = trim_slash(out_dir)

  use temp <- temporary.create(temporary.directory())

  // Either of these branches create the temporary output directory. Unlike above
  // we're using `result.try` here because we definitely want to know if something
  // goes wrong!
  use _ <- result.try(
    case static_dir {
      Some(path) -> simplifile.copy_directory(path, temp)
      None -> simplifile.create_directory_all(temp)
    }
    |> result.map_error(CannotCreateTempDirectory),
  )

  use _ <- result.try({
    use #(path, content) <- list.try_map(dict.to_list(static_assets))
    let dir = filepath.directory_name(path)

    filepath.join(temp, dir)
    |> simplifile.create_directory_all
    |> result.try(fn(_) { simplifile.write(temp <> path, content) })
    |> result.map_error(CannotWriteStaticAsset(_, path))
  })

  // Try to generate every route. By using `list.try_map` we can stop generating
  // routes as soon as one fails. This is useful because we don't want to generate
  // garbage
  //
  // If any of these do fail, we exit out of the build without performing any
  // cleanup. This means in temp directory will be left with the partially generated
  // site. Probably in the future we'd want to perform some cleanup but it made
  // the code a bit clunky so I've left it out for now.
  use _ <- result.try({
    let routes = list.sort(routes, fn(a, b) { string.compare(a.path, b.path) })
    use route <- list.try_map(routes)

    case route {
      Static("/", el) -> {
        let path = temp <> "/index.html"

        el
        |> element.to_document_string
        |> simplifile.write(path, _)
        |> result.map_error(CannotGenerateRoute(_, path))
      }

      Static(path, el) if use_index_routes -> {
        let _ = simplifile.create_directory_all(temp <> path)
        let path = temp <> trim_slash(path) <> "/index.html"

        el
        |> element.to_document_string
        |> simplifile.write(path, _)
        |> result.map_error(CannotGenerateRoute(_, path))
      }

      Static(path, el) -> {
        let #(path, name) = last_segment(path)
        let _ = simplifile.create_directory_all(temp <> path)
        let path = temp <> trim_slash(path) <> "/" <> name <> ".html"

        el
        |> element.to_document_string
        |> simplifile.write(path, _)
        |> result.map_error(CannotGenerateRoute(_, path))
      }

      Dynamic(path, pages) -> {
        let _ = simplifile.create_directory_all(temp <> path)
        use _, #(page, el) <- list.try_fold(dict.to_list(pages), Nil)
        let path = temp <> trim_slash(path) <> "/" <> routify(page) <> ".html"

        el
        |> element.to_document_string
        |> simplifile.write(path, _)
        |> result.map_error(CannotGenerateRoute(_, path))
      }

      Xml(path, el) -> {
        let #(path, name) = last_segment(path)
        let _ = simplifile.create_directory_all(temp <> path)
        let path = temp <> trim_slash(path) <> "/" <> name <> ".xml"

        el
        |> element.to_string
        |> string.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", _)
        |> simplifile.write(path, _)
        |> result.map_error(CannotGenerateRoute(_, path))
      }
    }
  })

  // If a previous build has already happened, we want to delete it and also
  // make sure we catch any simplifile errors. But attempting to delete a directory
  // that doesn't exist will throw an error so instead we do nothing.
  use _ <- result.try(
    case result.unwrap(simplifile.is_directory(out_dir), False) {
      True ->
        simplifile.delete(out_dir)
        |> result.map_error(CannotWriteToOutputDir)
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(
    simplifile.copy_directory(temp, out_dir)
    |> result.map_error(CannotWriteToOutputDir),
  )

  Ok(Nil)
}

// TYPES -----------------------------------------------------------------------

/// The `Config` type tells `lustre_ssg` how to generate your site. It includes
/// things like the output directory and any routes you have configured.
///
/// The type parameters are used to track different facts about the configuration
/// and prevent silly things from happening like building a site with no guaranteed
/// routes.
///
/// If you're looking at the generated documentation on hex.pm, these type parameters
/// might be unhelpfully labelled "a", "b", "c", etc. Here's a look at what these
/// type parameters are called in the source code:
///
/// ```
/// pub opaque type Config(
///   has_static_routes,
///   has_static_dir,
///   use_index_routes
/// )
/// ```
///
/// - `has_static_routes` indicates whether or not the configuration has at least
///   one static route and so is guarnateed to generate at least one HTML file.
///   It will be either `HasStaticRoutes` or `NoStaticRoutes`.
///
///   You need to add at least one static route before you can build your site
///   using [`build`](#build). This is to prevent you from providing empty dynamic
///   routes and accidentally building nothing.
///
/// - `has_static_dir` indicates whether or not the configuration has a static
///   assets directory to copy. It will be either `HasStaticDir` or `NoStaticDir`.
///
///   The [`build`](#build) function will run regardless, but you may choose to
///   wrap this function yourself to provider stricter compile-time guarantees
///   if you want to ensure that your static assets are always configured.
///
/// - `use_index_routes` indicates whether or not the configuration will generate
///   HTML files that correspond directly to the route provided or if an index.html
///   file will be generated at the route provided. It will be either `UseDirectRoutes`
///   or `UseIndexRoutes`.
///
///   As with `has_static_dir`, the [`build`](#build) function will run regardless,
///   but you may use this parameter for stricter compile-time guarantees.
///
pub opaque type Config(has_static_routes, has_static_dir, use_index_routes) {
  Config(
    out_dir: String,
    static_dir: Option(String),
    static_assets: Dict(String, String),
    routes: List(Route),
    use_index_routes: Bool,
  )
}

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that will not generate any static routes.
///
/// Your configuration must have at least one static route before it can be passed
/// to `build`. This is to prevent you from accidentally building a completely
/// empty site.
///
pub type NoStaticRoutes

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that does not have a statica ssets directory to
/// copy.
///
pub type NoStaticDir

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that will generate least one static route.
///
pub type HasStaticRoutes

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that has a static assets directory to copy.
///
pub type HasStaticDir

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that will generate HTML files that correspond
/// directly to the route provided, for example the route "/blog" will generate
/// a file at "/blog.html".
///
pub type UseDirectRoutes

/// This type is used to tag the `Config` through the different builder functions.
/// It indicates a configuration that will generate an `index.html` file at the
/// route provided, for example the route "/blog" will generate a file at
/// "/blog/index.html".
///
pub type UseIndexRoutes

type Route {
  Static(path: String, page: Element(Nil))
  Dynamic(path: String, pages: Dict(String, Element(Nil)))
  Xml(path: String, page: Element(Nil))
}

/// This type represents possible errors that can occur when building the site.
///
pub type BuildError {
  /// An error that can occur when trying to create a temporary directory to
  /// work in: when generating a static site, lustre_ssg first writes all the
  /// files in a temporary directory. After the generation is over, all the
  /// contents of the temporary directory are copied over to the actual output
  /// directory.
  ///
  CannotCreateTempDirectory(reason: simplifile.FileError)

  /// An error that can occur when trying to write a static asset to a given
  /// path.
  ///
  CannotWriteStaticAsset(reason: simplifile.FileError, path: String)

  /// An error that can occur when trying to generate a route at a given path.
  ///
  CannotGenerateRoute(reason: simplifile.FileError, path: String)

  /// An error that can occur when the building step is over and all generated
  /// documents are moved from the temporary directory to the actual output
  /// directory.
  ///
  CannotWriteToOutputDir(reason: simplifile.FileError)

  /// An error that can occur when trying to delete the temporary directory.
  ///
  CannotCleanupTempDir(reason: simplifile.FileError)
}

// BUILDERS --------------------------------------------------------------------

/// Configure a static route to be generated. The path should be the route that
/// the page will be available at when served by a HTTP server. For example the
/// path "/blog" would be available at "https://your_site.com/blog".
///
/// You need to add at least one static route before you can build your site. This
/// is to prevent you from providing empty dynamic routes and accidentally building
/// nothing.
///
/// Paths are converted to kebab-case and lowercased. This means that the path
/// "/Blog" will be available at "/blog" and and "/About me" will be available at
/// "/about-me".
///
pub fn add_static_route(
  config: Config(has_static_routes, has_static_dir, use_index_routes),
  path: String,
  page: Element(a),
) -> Config(HasStaticRoutes, has_static_dir, use_index_routes) {
  let Config(out_dir, static_dir, static_assets, routes, use_index_routes) =
    config
  let route = Static(routify(path), element.map(page, fn(_) { Nil }))

  // We must reconstruct the `Config` entirely instead of using Gleam's spread
  // operator because we need to change the type of the configuration. Specifically,
  // we're adding the `HasStaticRoutes` type parameter.
  Config(
    out_dir,
    static_dir,
    static_assets,
    [route, ..routes],
    use_index_routes,
  )
}

///
///
pub fn add_static_xml(
  config: Config(has_static_routes, has_static_dir, use_index_routes),
  path: String,
  page: Element(a),
) -> Config(has_static_routes, has_static_dir, use_index_routes) {
  let Config(out_dir, static_dir, static_assets, routes, use_index_routes) =
    config
  let route = Xml(routify(path), element.map(page, fn(_) { Nil }))

  // We must reconstruct the `Config` entirely instead of using Gleam's spread
  // operator because we need to change the type of the configuration. Specifically,
  // we're adding the `HasStaticRoutes` type parameter.
  Config(
    out_dir,
    static_dir,
    static_assets,
    [route, ..routes],
    use_index_routes,
  )
}

/// Configure a map of dynamic routes to be generated. As with `add_static_route`
/// the base path should be the route that each page will be available at when
/// served by a HTTP server.
///
/// The initial path is the base for all dynamic routes to be generated. The
/// keys of the `data` map will be used to generate the dynamic routes. For
/// example, to generate dynamic routes for a blog where each page is a post
/// with the route "/blog/:post" you might do:
///
/// ```gleam
/// let posts = [
///   #("hello-world", Post(...)),
///   #("why-lustre-is-great", Post(...)),
/// ]
///
/// ...
///
/// ssg.config("./dist")
/// |> ...
/// |> ssg.add_dynamic_route("/blog", posts, render_post)
/// ```
///
/// Paths are converted to kebab-case and lowercased. This means that the path
/// "/Blog" will be available at "/blog" and and "/About me" will be available at
/// "/about-me".
///
pub fn add_dynamic_route(
  config: Config(has_static_routes, has_static_dir, use_index_routes),
  path: String,
  data: Dict(String, a),
  page: fn(a) -> Element(b),
) -> Config(has_static_routes, has_static_dir, use_index_routes) {
  let route = {
    let path = routify(path)
    let pages =
      dict.map_values(data, fn(_, data) {
        element.map(page(data), fn(_) { Nil })
      })

    Dynamic(path, pages)
  }

  Config(..config, routes: [route, ..config.routes])
}

/// Include a static directory from which all files will be copied over into
/// the temporary build directory before building the site.
///
pub fn add_static_dir(
  config: Config(has_static_routes, NoStaticDir, use_index_routes),
  path: String,
) -> Config(has_static_routes, HasStaticDir, use_index_routes) {
  let Config(out_dir, _, static_assets, routes, use_index_routes) = config

  // We must reconstruct the `Config` entirely instead of using Gleam's spread
  // operator because we need to change the type of the configuration. Specifically,
  // we're adding the `HasStaticDir` type parameter.
  Config(out_dir, Some(path), static_assets, routes, use_index_routes)
}

/// Include a static asset in the generated site. This might be something you
/// want to be generated at build time, like a robots.txt, a sitemap.xml, or
/// an RSS feed.
///
/// The path should be the path that the asset will be available at when served
/// by an HTTP server. For example, the path "/robots.txt" would be available at
/// "https://your_site.com/robots.txt". The path will be converted to kebab-case
/// and lowercased.
///
/// If you have configured a static assets directory to be copied over, any static
/// asset added here will overwrite any file with the same path.
///
pub fn add_static_asset(
  config: Config(has_static_routes, has_static_dir, use_index_routes),
  path: String,
  content: String,
) -> Config(has_static_routes, has_static_dir, use_index_routes) {
  let static_assets = dict.insert(config.static_assets, routify(path), content)

  Config(..config, static_assets: static_assets)
}

// CONFIGURATION ---------------------------------------------------------------

/// Configure the static site generator to generate an `index.html` file at any
/// static route provided. For example, the route "/blog" will generate a file
/// at "/blog/index.html".
///
pub fn use_index_routes(
  config: Config(has_static_routes, has_static_dir, use_index_routes),
) -> Config(has_static_routes, has_static_dir, UseIndexRoutes) {
  let Config(out_dir, static_dir, static_assets, routes, _) = config

  // We must reconstruct the `Config` entirely instead of using Gleam's spread
  // operator because we need to change the type of the configuration. Specifically,
  // we're adding the `UseIndexRoutes` type parameter.
  Config(out_dir, static_dir, static_assets, routes, True)
}

// UTILS -----------------------------------------------------------------------

fn routify(path: String) -> String {
  let assert Ok(whitespace) = regexp.from_string("\\s+")

  regexp.split(whitespace, path)
  |> string.join("-")
  |> string.lowercase
}

fn trim_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}

fn last_segment(path: String) -> #(String, String) {
  let assert Ok(segments) = regexp.from_string("(.*/)+?(.+)")
  let assert [regexp.Match(content: _, submatches: [Some(leading), Some(last)])] =
    regexp.scan(segments, path)

  #(leading, last)
}
