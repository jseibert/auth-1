import Authentication
import Dispatch
import FluentSQLite
import Vapor
import XCTest

class AuthenticationTests: XCTestCase {
    func testPassword() throws {
        let queue = try MultiThreadedEventLoopGroup(numThreads: 1)
        
        let database = try SQLiteDatabase(storage: .memory)
        let conn = try database.makeConnection(on: queue).wait()

        try User.prepare(on: conn).wait()
        let user = User(name: "Tanner", email: "tanner@vapor.codes", password: "foo")
        _ = try user.save(on: conn).wait()
        let password = BasicAuthorization(username: "tanner@vapor.codes", password: "foo")
        let authed = try User.authenticate(using: password, verifier: PlaintextVerifier(), on: conn).wait()
        XCTAssertEqual(authed?.id, user.id)
    }

    func testApplication() throws {
        var services = Services.default()
        try services.register(FluentProvider())
        try services.register(FluentSQLiteProvider())
        try services.register(AuthenticationProvider())

        let sqlite = try SQLiteDatabase(storage: .memory)
        var databases = DatabaseConfig()
        databases.add(database: sqlite, as: .test)
        services.register(databases)

        var migrations = MigrationConfig()
        migrations.add(model: User.self, database: .test)
        services.register(migrations)

        let app = try Application(services: services)

        let conn = try app.requestConnection(to: .test).wait()
        defer { app.releaseConnection(conn, to: .test) }

        let user = User(name: "Tanner", email: "tanner@vapor.codes", password: "foo")
        _ = try user.save(on: conn).wait()
        let router = try app.make(Router.self)

        let password = User.basicAuthMiddleware(using: PlaintextVerifier())
        let group = router.grouped(password)
        group.get("test") { req -> String in
            let user = try req.requireAuthenticated(User.self)
            return user.name
        }

        let req = Request(using: app)
        req.http.method = .GET
        req.http.urlString = "/test"
        req.http.headers.basicAuthorization = .init(username: "tanner@vapor.codes", password: "foo")

        let responder = try app.make(Responder.self)
        let res = try responder.respond(to: req).wait()
        XCTAssertEqual(res.http.status, .ok)
        try XCTAssertEqual(res.http.body.consumeData(max: 100, on: app).wait(), Data("Tanner".utf8))
    }

    func testSessionPersist() throws {
        var services = Services.default()
        try services.register(FluentSQLiteProvider())
        try services.register(AuthenticationProvider())

        let sqlite = try SQLiteDatabase(storage: .memory)
        var databases = DatabaseConfig()
        databases.add(database: sqlite, as: .test)
        services.register(databases)

        var migrations = MigrationConfig()
        migrations.add(model: User.self, database: .test)
        services.register(migrations)

        var middleware = MiddlewareConfig.default()
        middleware.use(SessionsMiddleware.self)
        services.register(middleware)
        services.register(MemoryKeyedCache(on: EmbeddedEventLoop()), as: KeyedCache.self)

        var config = Config.default()
        config.prefer(MemoryKeyedCache.self, for: KeyedCache.self)

        let app = try Application(config: config, services: services)

        let conn = try app.requestConnection(to: .test).wait()
        defer { app.releaseConnection(conn, to: .test) }

        let user = User(name: "Tanner", email: "tanner@vapor.codes", password: "foo")
        _ = try user.save(on: conn).wait()

        let router = try app.make(Router.self)

        let group = router.grouped(
            User.basicAuthMiddleware(using: PlaintextVerifier()),
            User.authSessionsMiddleware()
        )
        group.get("test") { req -> String in
            let user = try req.requireAuthenticated(User.self)
            return user.name
        }


        let responder = try app.make(Responder.self)

        /// non-authed req
        do {
            let req = Request(using: app)
            req.http.method = .GET
            req.http.urlString = "/test"

            let res = try responder.respond(to: req).wait()
            XCTAssertEqual(res.http.status, .unauthorized)
        }

        /// authed req
        let session: String
        do {
            let req = Request(using: app)
            req.http.method = .GET
            req.http.urlString = "/test"
            req.http.headers.basicAuthorization = .init(username: "tanner@vapor.codes", password: "foo")

            let res = try responder.respond(to: req).wait()
            XCTAssertEqual(res.http.status, .ok)
            try XCTAssertEqual(res.http.body.consumeData(max: 100, on: app).wait(), Data("Tanner".utf8))
            session = String(res.http.headers[.setCookie].first!.split(separator: ";").first!)
        }

        /// persisted req
        do {
            let req = Request(using: app)
            req.http.method = .GET
            req.http.urlString = "/test"
            req.http.headers.replaceOrAdd(name: .cookie, value: session)


            let res = try responder.respond(to: req).wait()
            XCTAssertEqual(res.http.status, .ok)
            try XCTAssertEqual(res.http.body.consumeData(max: 100, on: app).wait(), Data("Tanner".utf8))
        }

        /// persisted, no-session req
        do {
            let req = Request(using: app)
            req.http.method = .GET
            req.http.urlString = "/test"

            let res = try responder.respond(to: req).wait()
            XCTAssertEqual(res.http.status, .unauthorized)
        }
    }

    static var allTests = [
        ("testPassword", testPassword),
        ("testApplication", testApplication),
        ("testSessionPersist", testSessionPersist),
    ]
}
