//
//  PrivateWebReqeustHandler.swift
//  RealDeviceMap
//
//  Created by Florian Kostenzer on 18.09.18.
//

import Foundation
import PerfectLib
import PerfectHTTP
import PerfectMustache
import PerfectSessionMySQL

class WebReqeustHandler {
    
    class CompletedEarly: Error {}
    
    static var isSetup = false
    static var accessToken: String?
    
    static var startLat: Double = 0
    static var startLon: Double = 0
    static var startZoom: Int = 14
    static var maxPokemonId: Int = 493
    static var title: String = "RealDeviceMap"
    static var avilableFormsJson: String = ""
    
    private static let sessionDriver = MySQLSessions()
        
    static func handle(request: HTTPRequest, response: HTTPResponse, page: WebServer.Page, requiredPerms: [Group.Perm], requiredPermsCount:Int = -1) {
        
        let localizer = Localizer.global
        
        let documentRoot = Dir.workingDir.path + "/resources/webroot"
        var data = MustacheEvaluationContext.MapType()
        data["csrf"] = request.session?.data["csrf"]
        data["timestamp"] = UInt32(Date().timeIntervalSince1970)
        data["locale"] = Localizer.locale
        data["locale_last_modified"] = localizer.lastModified
        
        // Localize Navbar
        let navLoc = ["nav_dashboard", "nav_stats", "nav_logout", "nav_register", "nav_login"]
        for loc in navLoc {
            data[loc] = localizer.get(value: loc)
        }
        
        // Get User
        var username = request.session?.userid
        if username != nil && username != "" {
            data["username"] = username
            data["is_logged_in"] = true
        }
        
        var perms = [Group.Perm]()
        let sessionPerms = (request.session?.data["perms"] as? Int)?.toUInt32()
        if sessionPerms == nil {
            if username != nil && username != "" {
                let user: User?
                do {
                    user = try User.get(username: username!)
                } catch {
                    user = nil
                }
                if user == nil {
                    request.session?.userid = ""
                    username = ""
                    perms = []
                } else {
                    let userPerms = user!.group?.perms
                    perms = userPerms ?? []
                    request.session?.data["perms"] = Group.Perm.permsToNumber(perms: userPerms ?? [])
                }
            }
            if username == nil || username == "" {
                let group: Group?
                do {
                    group = try Group.getWithName(name: "no_user")
                } catch {
                    group = nil
                }
                if group == nil {
                    perms = [Group.Perm]()
                } else {
                    let userPerms = group!.perms
                    perms = userPerms
                    request.session?.data["perms"] = Group.Perm.permsToNumber(perms: userPerms)
                }
            }
        } else {
            perms = Group.Perm.numberToPerms(number: sessionPerms!)
        }
        
        var requiredPermsCountReal: Int
        if requiredPermsCount == -1 {
            requiredPermsCountReal = requiredPerms.count
        } else {
            requiredPermsCountReal = requiredPermsCount
        }
        var requiredPermsFound = 0
        for perm in requiredPerms {
            if perms.contains(perm) {
                requiredPermsFound += 1
            }
        }
        if requiredPermsCountReal > requiredPermsFound {
            if username != nil && username != "" {
                response.setBody(string: "Unauthorized.")
                sessionDriver.save(session: request.session!)
                response.completed(status: .unauthorized)
                return
            } else {
                response.setBody(string: "Unauthorized. Log in first.")
                response.redirect(path: "/login")
                sessionDriver.save(session: request.session!)
                response.completed(status: .found)
                return
            }
        }
        
        if perms.contains(.viewStats) {
            data["show_stats"] = true
        }
 
        if perms.contains(.adminUser) || perms.contains(.adminSetting) {
            data["show_dashboard"] = true
        }
        
        if (!isSetup && page != .setup) {
            response.setBody(string: "Setup required.")
            response.redirect(path: "/setup")
            sessionDriver.save(session: request.session!)
            response.completed(status: .found)
            return
        }
        if (isSetup && page == .setup) {
            response.setBody(string: "Setup already completed.")
            response.redirect(path: "/")
            sessionDriver.save(session: request.session!)
            response.completed(status: .movedPermanently)
            return
        }
        
        data["title"] = title
        switch page {
        case .home:
            data["page_is_home"] = true
            data["page"] = "Home"
            data["hide_gyms"] = !perms.contains(.viewMapGym)
            data["hide_pokestops"] = !perms.contains(.viewMapPokestop)
            data["hide_raids"] = !perms.contains(.viewMapRaid)
            data["hide_pokemon"] = !perms.contains(.viewMapPokemon)
            data["hide_spawnpoints"] = !perms.contains(.viewMapSpawnpoint)
            
            // Localize
            let homeLoc = ["filter_title", "filter_gyms", "filter_raids", "filter_pokestops", "filter_spawnpoints", "filter_pokemon", "filter_filter", "filter_cancel", "filter_close", "filter_hide", "filter_show", "filter_reset", "filter_disable_all", "filter_pokemon_filter", "filter_save", "filter_image", "filter_size"]
            for loc in homeLoc {
                data[loc] = localizer.get(value: loc)
            }
            
        case .dashboard:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard"
            data["show_setting"] = perms.contains(.adminSetting)
            data["show_user"] = perms.contains(.adminUser)
        case .dashboardSettings:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Settings"
            if request.method == .post {
                do {
                    data = try updateSettings(data: data, request: request, response: response)
                } catch {
                    return
                }
            }
            data["start_lat"] = startLat
            data["start_lon"] = startLon
            data["start_zoom"] = startZoom
            data["max_pokemon_id"] = maxPokemonId
            data["locale_new"] = Localizer.locale
            data["webhook_urls"] = WebHookController.global.webhookURLStrings.joined(separator: ";")
            data["webhook_delay"] = WebHookController.global.webhookSendDelay
            data["pokemon_time_new"] = Pokemon.defaultTimeUnseen
            data["pokemon_time_old"] = Pokemon.defaultTimeReseen
        case .dashboardDevices:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Devices"
        case .dashboardDeviceAssign:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Assign Device"
            let deviceUUID = request.urlVariables["device_uuid"] ?? ""

            data["device_uuid"] = deviceUUID
            if request.method == .post {
                do {
                    data = try assignDevicePost(data: data, request: request, response: response, deviceUUID: deviceUUID)
                } catch {
                    return
                }
            } else {
                do {
                    data = try assignDeviceGet(data: data, request: request, response: response, deviceUUID: deviceUUID)
                } catch {
                    return
                }
            }
        case .dashboardInstances:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Instances"
        case .dashboardInstanceAdd:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Add Instance"
            if request.method == .post {
                do {
                    data = try addInstance(data: data, request: request, response: response)
                } catch {
                    return
                }
            } else {
                data["nothing_selected"] = true
            }
        case .dashboardAccounts:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Accounts"
            data["new_accounts_count"] = (try? Account.getNewCount()) ?? "?"
            data["in_use_accounts_count"] = (try? Account.getInUseCount()) ?? "?"
            data["warned_accounts_count"] = (try? Account.getWarnedCount()) ?? "?"
            data["failed_accounts_count"] = (try? Account.getFailedCount()) ?? "?"
        case .dashboardAccountsAdd:
            data["page_is_dashboard"] = true
            data["page"] = "Dashboard - Add Accounts"
            if request.method == .post {
                do {
                    data = try addAccounts(data: data, request: request, response: response)
                } catch {
                    return
                }
            } else {
                data["low_level_selected"] = true
            }
        case .dashboardInstanceEdit:
            let instanceName = (request.urlVariables["instance_name"] ?? "").replacingOccurrences(of: "&dash&", with: "/")
            data["page_is_dashboard"] = true
            data["old_name"] = instanceName
            data["page"] = "Dashboard - Edit Instance"
            
            if request.param(name: "delete") == "true" {
                do {
                    try Instance.delete(name: instanceName)
                    InstanceController.global.removeInstance(instanceName: instanceName)
                    response.redirect(path: "/dashboard/instances")
                    sessionDriver.save(session: request.session!)
                    response.completed(status: .seeOther)
                    return
                } catch {
                    response.setBody(string: "Internal Server Error")
                    sessionDriver.save(session: request.session!)
                    response.completed(status: .internalServerError)
                    return
                }
                
            } else if request.method == .post {
                do {
                    data = try editInstancePost(data: data, request: request, response: response, instanceName: instanceName)
                } catch {
                    return
                }
            } else {
                do {
                    data = try editInstanceGet(data: data, request: request, response: response, instanceName: instanceName)
                } catch {
                    return
                }
            }
        case .register:
            data["page_is_register"] = true
            data["page"] = "Register"
            
            // Localize
            let homeLoc = ["register_username", "register_email", "register_password", "register_retype_password", "register_register"]
            for loc in homeLoc {
                data[loc] = localizer.get(value: loc)
            }
            data["register_title"] = localizer.get(value: "register_title", replace: ["name" : title])
            
            if request.method == .post {
                do {
                    data = try register(data: data, request: request, response: response, useAccessToken: false)
                } catch {
                    return
                }
            }
        case .login:
            data["page_is_login"] = true
            data["page"] = "Login"
            
            // Localize
            let homeLoc = ["login_username_email", "login_password", "login_login"]
            for loc in homeLoc {
                data[loc] = localizer.get(value: loc)
            }
            data["login_title"] = localizer.get(value: "login_title", replace: ["name" : title])
            
            if request.method == .post {
                do {
                    data = try login(data: data, request: request, response: response)
                } catch {
                    return
                }
            }
        case .logout:
            data["page"] = "Logout"
            do {
                try logout(data: data, request: request, response: response)
            } catch {
                return
            }
        case .setup:
            data["page"] = "Setup"
            if request.method == .post {
                do {
                    data = try register(data: data, request: request, response: response, useAccessToken: true)
                } catch {
                    return
                }
            }
        case .homeJs:
            data["start_lat"] = startLat
            data["start_lon"] = startLon
            data["start_zoom"] = startZoom
            data["max_pokemon_id"] = maxPokemonId
            data["avilable_forms_json"] = avilableFormsJson
        default:
            break
        }
        
        if page == .homeJs {
            response.setHeader(.contentType, value: "application/javascript")
        } else if page == .homeCss {
            response.setHeader(.contentType, value: "text/css")
        } else {
            response.setHeader(.contentType, value: "text/html")
        }
        mustacheRequest(
            request: request,
            response: response,
            handler: WebPageHandler(page: page, data: data),
            templatePath: documentRoot + "/" + page.rawValue
        )
        if (page != .homeJs && page != .homeCss) {
            sessionDriver.save(session: request.session!)
        }
        response.completed()
    }
    
    static func logout(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse) throws {
        request.session?.userid = ""
        request.session?.data["perms"] = nil
        let redirect = request.param(name: "redirect") ?? "/"
        response.redirect(path: redirect)
        sessionDriver.save(session: request.session!)
        response.completed(status: .found)
        throw CompletedEarly()
    }
    
    static func register(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse, useAccessToken: Bool) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        
        let username = request.param(name: "username")
        let password = request.param(name: "password")
        let passwordRetype = request.param(name: "password-retype")
        let email = request.param(name: "email")
        let accessToken = request.param(name: "access-token")
        
        var noError = true
        
        if password != passwordRetype {
            data["is_password_retype_error"] = true
            data["password_retype_error"] = "The passwords do not match."
            data["is_password_error"] = true
            data["password_error"] = "The passwords do not match."
            noError = false
        }
        if useAccessToken && accessToken != self.accessToken {
            data["is_access_token_error"] = true
            data["access_token_error"] = "Wrong access token."
            noError = false
        }
        if username == nil || username == "" {
            data["is_username_error"] = true
            data["username_error"] = "Username can not be empty."
            noError = false
        }
        if email == nil || email == "" {
            data["is_email_error"] = true
            data["email_error"] = "Email can not be empty."
            noError = false
        }
        
        if noError {
            var user: User?
            do {
                let groupName: String
                if useAccessToken {
                    groupName = "root"
                } else {
                    groupName = "default"
                }
                user = try User.register(username: username!, email: email!, password: password!, groupName: groupName)
            } catch {
                let localizer = Localizer.global
                if error is DBController.DBError {
                    data["is_undefined_error"] = true
                    data["undefined_error"] = localizer.get(value: "register_error_undefined")
                } else {
                    let registerError = error as! User.RegisterError
                    switch registerError.type {
                    case .usernameInvalid:
                        data["is_username_error"] = true
                        data["username_error"] = localizer.get(value: "register_error_username_invalid")
                    case .usernameTaken:
                        data["is_username_error"] = true
                        data["username_error"] = localizer.get(value: "register_error_username_taken")
                    case .emailInvalid:
                        data["is_email_error"] = true
                        data["email_error"] = localizer.get(value: "register_error_email_invalid")
                    case .emailTaken:
                        data["is_email_error"] = true
                        data["email_error"] = localizer.get(value: "register_error_email_taken")
                    case .passwordInvalid:
                        data["is_password_error"] = true
                        data["password_error"] = localizer.get(value: "register_error_password_invalid")
                    case .undefined:
                        data["is_undefined_error"] = true
                        data["undefined_error"] = localizer.get(value: "register_error_undefined")
                    }
                }
            }
            
            if user != nil {
                request.session?.userid = user!.username
                if user!.group != nil {
                    request.session?.data["perms"] = Group.Perm.permsToNumber(perms: user!.group!.perms)
                }
                if useAccessToken {
                    try DBController.global.setValueForKey(key: "IS_SETUP", value: "true")
                    WebReqeustHandler.isSetup = true
                    WebReqeustHandler.accessToken = nil
                    response.redirect(path: "/")
                    sessionDriver.save(session: request.session!)
                    response.completed(status: .seeOther)
                    throw CompletedEarly()
                } else {
                    let redirect = request.param(name: "redirect") ?? "/"
                    response.redirect(path: redirect)
                    sessionDriver.save(session: request.session!)
                    response.completed(status: .seeOther)
                    throw CompletedEarly()
                }
            }
        }
        
        data["username"] = username
        data["password"] = password
        data["password-retype"] = passwordRetype
        data["email"] = email
        if useAccessToken {
            data["access-token"] = accessToken
        }
        
        return data
    }
    
    static func login(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        
        let usernameEmail = request.param(name: "username-email") ?? ""
        let password = request.param(name: "password") ?? ""
        
        var user: User?
        do {
            if usernameEmail.contains("@") {
                user = try User.login(email: usernameEmail, password: password)
            } else {
                user = try User.login(username: usernameEmail, password: password)
            }
        } catch {
            let localizer = Localizer.global
            if error is DBController.DBError {
                data["is_error"] = true
                data["error"] = localizer.get(value: "login_error_undefined")
            } else {
                let registerError = error as! User.LoginError
                switch registerError.type {
                case .usernamePasswordInvalid:
                    data["is_error"] = true
                    data["error"] = localizer.get(value: "login_error_invalid")
                case .undefined:
                    data["is_error"] = true
                    data["error"] = localizer.get(value: "login_error_undefined")
                }
            }
        }
        
        if user != nil {
            request.session?.userid = user!.username
            if user!.group != nil {
                request.session?.data["perms"] = Group.Perm.permsToNumber(perms: user!.group!.perms)
            }
            let redirect = request.param(name: "redirect") ?? "/"
            response.redirect(path: redirect)
            sessionDriver.save(session: request.session!)
            response.completed(status: .seeOther)
            throw CompletedEarly()
        }
        
        data["username-email"] = usernameEmail
        data["password"] = password
        
        return data
    }
 
    static func updateSettings(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        guard
            let startLat = request.param(name: "start_lat")?.toDouble(),
            let startLon = request.param(name: "start_lon")?.toDouble(),
            let startZoom = request.param(name: "start_zoom")?.toInt(),
            let title = request.param(name: "title"),
            let defaultTimeUnseen = request.param(name: "pokemon_time_new")?.toUInt32(),
            let defaultTimeReseen = request.param(name: "pokemon_time_old")?.toUInt32(),
            let maxPokemonId = request.param(name: "max_pokemon_id")?.toInt(),
            let locale = request.param(name: "locale_new")?.lowercased()
        else {
            data["show_error"] = true
            return data
        }
        
        let webhookDelay = request.param(name: "webhook_delay")?.toDouble() ?? 5.0
        let webhookUrlsString = request.param(name: "webhook_urls") ?? ""
        let webhookUrls = webhookUrlsString.components(separatedBy: ";")
        
        do {
            try DBController.global.setValueForKey(key: "MAP_START_LAT", value: startLat.description)
            try DBController.global.setValueForKey(key: "MAP_START_LON", value: startLon.description)
            try DBController.global.setValueForKey(key: "MAP_START_ZOOM", value: startZoom.description)
            try DBController.global.setValueForKey(key: "TITLE", value: title)
            try DBController.global.setValueForKey(key: "WEBHOOK_DELAY", value: webhookDelay.description)
            try DBController.global.setValueForKey(key: "WEBHOOK_URLS", value: webhookUrlsString)
            try DBController.global.setValueForKey(key: "POKEMON_TIME_UNSEEN", value: defaultTimeUnseen.description)
            try DBController.global.setValueForKey(key: "POKEMON_TIME_RESEEN", value: defaultTimeReseen.description)
            try DBController.global.setValueForKey(key: "MAP_MAX_POKEMON_ID", value: maxPokemonId.description)
            try DBController.global.setValueForKey(key: "LOCALE", value: locale)
        } catch {
            data["show_error"] = true
            return data
        }
        
        WebReqeustHandler.startLat = startLat
        WebReqeustHandler.startLon = startLon
        WebReqeustHandler.startZoom = startZoom
        WebReqeustHandler.title = title
        WebReqeustHandler.maxPokemonId = maxPokemonId
        WebHookController.global.webhookSendDelay = webhookDelay
        WebHookController.global.webhookURLStrings = webhookUrls
        Pokemon.defaultTimeUnseen = defaultTimeUnseen
        Pokemon.defaultTimeReseen = defaultTimeReseen
        Localizer.locale = locale
        
        data["title"] = title
        data["show_success"] = true
        
        return data
    }
    
    static func addInstance(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        guard
            let name = request.param(name: "name"),
            let type = request.param(name: "type"),
            let area = request.param(name: "area")?.replacingOccurrences(of: "<br>", with: "").replacingOccurrences(of: "\r\n", with: "\n", options: .regularExpression)
        else {
            data["show_error"] = true
            data["error"] = "Invalid Request."
            return data
        }
        
        data["name"] = name
        data["area"] = area
        if type.lowercased() == "circle_pokemon" {
            data["circle_pokemon_selected"] = true
        } else if type.lowercased() == "circle_raid" {
            data["circle_raid_selected"] = true
        } else {
            data["nothing_selected"] = true
        }
        
        var coords = [Coord]()
        let areaRows = area.components(separatedBy: "\n")
        for areaRow in areaRows {
            let rowSplit = areaRow.components(separatedBy: ",")
            if rowSplit.count == 2 {
                let lat = rowSplit[0].toDouble()
                let lon = rowSplit[1].toDouble()
                if lat != nil && lon != nil {
                    coords.append(Coord(lat: lat!, lon: lon!))
                }
            }
        }
        
        if coords.count == 0 {
            data["show_error"] = true
            data["error"] = "Failed to parse coords."
            return data
        } else {
            let instance = Instance(name: name, type: Instance.InstanceType.fromString(type)!, data: ["area" : coords])
            do {
                try instance.create()
                InstanceController.global.addInstance(instance: instance)
            } catch {
                data["show_error"] = true
                data["error"] = "Failed to create instance. Is the name unique?"
                return data
            }
            response.redirect(path: "/dashboard/instances")
            sessionDriver.save(session: request.session!)
            response.completed(status: .seeOther)
            throw CompletedEarly()
        }
    }
    
    static func editInstancePost(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse, instanceName: String) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        guard
            let name = request.param(name: "name"),
            let type = request.param(name: "type"),
            let area = request.param(name: "area")?.replacingOccurrences(of: "<br>", with: "").replacingOccurrences(of: "\r\n", with: "\n", options: .regularExpression)
            else {
                data["show_error"] = true
                data["error"] = "Invalid Request."
                return data
        }
    
        data["name"] = name
        data["area"] = area
        if type.lowercased() == "circle_pokemon" {
            data["circle_pokemon_selected"] = true
        } else if type.lowercased() == "circle_raid" {
            data["circle_raid_selected"] = true
        } else {
            data["nothing_selected"] = true
        }
        
        var coords = [Coord]()
        let areaRows = area.components(separatedBy: "\n")
        for areaRow in areaRows {
            let rowSplit = areaRow.components(separatedBy: ",")
            if rowSplit.count == 2 {
                let lat = rowSplit[0].toDouble()
                let lon = rowSplit[1].toDouble()
                if lat != nil && lon != nil {
                    coords.append(Coord(lat: lat!, lon: lon!))
                }
            }
        }
        
        if coords.count == 0 {
            data["show_error"] = true
            data["error"] = "Failed to parse coords."
            return data
        } else {
            let oldInstance: Instance?
            do {
                oldInstance = try Instance.getByName(name: instanceName)
            } catch {
                data["show_error"] = true
                data["error"] = "Failed to update instance. Is the name unique?"
                return data
            }
            if oldInstance == nil {
                response.setBody(string: "Instance Not Found")
                sessionDriver.save(session: request.session!)
                response.completed(status: .notFound)
                throw CompletedEarly()
            } else {
                oldInstance!.name = name
                oldInstance!.type = Instance.InstanceType.fromString(type)!
                oldInstance!.data["area"] = coords
                try oldInstance!.update(oldName: instanceName)
                InstanceController.global.reloadInstance(newInstance: oldInstance!, oldInstanceName: instanceName)
                response.redirect(path: "/dashboard/instances")
                sessionDriver.save(session: request.session!)
                response.completed(status: .seeOther)
                throw CompletedEarly()
            }
        }
    }
    
    static func editInstanceGet(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse, instanceName: String) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        
        let oldInstance: Instance?
        do {
            oldInstance = try Instance.getByName(name: instanceName)
        } catch {
            response.setBody(string: "Internal Server Error")
            sessionDriver.save(session: request.session!)
            response.completed(status: .internalServerError)
            throw CompletedEarly()
        }
        if oldInstance == nil {
            response.setBody(string: "Instance Not Found")
            sessionDriver.save(session: request.session!)
            response.completed(status: .notFound)
            throw CompletedEarly()
        } else {
            
            var areaString = ""
            let area = oldInstance!.data["area"] as? [[String: Double]]
            if area != nil {
                for coordLine in area! {
                    let lat = coordLine["lat"]
                    let lon = coordLine["lon"]
                    areaString += "\(lat!),\(lon!)\n"
                }
            }
            
            data["name"] = oldInstance!.name
            data["area"] = areaString
            switch oldInstance!.type {
            case .circlePokemon:
                data["circle_pokemon_selected"] = true
            case .circleRaid:
                data["circle_raid_selected"] = true
            }
            return data
        }
    }
    
    static func assignDevicePost(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse, deviceUUID: String) throws -> MustacheEvaluationContext.MapType {

        var data = data
        guard let instanceName = request.param(name: "instance") else {
                data["show_error"] = true
                data["error"] = "Invalid Request."
                return data
        }
        
        let device: Device?
        let instances: [Instance]
        do {
            device = try Device.getById(id: deviceUUID)
            instances = try Instance.getAll()
        } catch {
            data["show_error"] = true
            data["error"] = "Failed to assign Device."
            return data
        }
        if device == nil {
            response.setBody(string: "Device Not Found")
            sessionDriver.save(session: request.session!)
            response.completed(status: .notFound)
            throw CompletedEarly()
        }
        var instancesData = [[String: Any]]()
        for instance in instances {
            instancesData.append(["name": instance.name, "selected": instance.name == instanceName])
        }
        data["instances"] = instancesData

        do {
            device!.instanceName = instanceName
            try device!.save(oldUUID: device!.uuid)
            InstanceController.global.reloadDevice(newDevice: device!, oldDeviceUUID: deviceUUID)
        } catch {
            data["show_error"] = true
            data["error"] = "Failed to assign Device."
            return data
        }
        response.redirect(path: "/dashboard/devices")
        sessionDriver.save(session: request.session!)
        response.completed(status: .seeOther)
        throw CompletedEarly()
        
    }

    static func assignDeviceGet(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse, deviceUUID: String) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        let instances: [Instance]
        let device: Device?
        do {
            device = try Device.getById(id: deviceUUID)
            instances = try Instance.getAll()
        } catch {
            response.setBody(string: "Internal Server Error")
            sessionDriver.save(session: request.session!)
            response.completed(status: .internalServerError)
            throw CompletedEarly()
        }
        if device == nil {
            response.setBody(string: "Device Not Found")
            sessionDriver.save(session: request.session!)
            response.completed(status: .notFound)
            throw CompletedEarly()
        }
        
        var instancesData = [[String: Any]]()
        for instance in instances {
            instancesData.append(["name": instance.name, "selected": instance.name == device!.instanceName])
        }
        data["instances"] = instancesData
        return data
        
    }
    
    static func addAccounts(data: MustacheEvaluationContext.MapType, request: HTTPRequest, response: HTTPResponse) throws -> MustacheEvaluationContext.MapType {
        
        var data = data
        
        guard
            let level = request.param(name: "level"),
            let accounts = request.param(name: "accounts")?.replacingOccurrences(of: "<br>", with: "").replacingOccurrences(of: "\r\n", with: "\n", options: .regularExpression).replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: ":", with: ",")
            else {
                data["show_error"] = true
                data["error"] = "Invalid Request."
                return data
        }
        
        data["accounts"] = accounts
        var isHighLevel: Bool
        if level.lowercased() == "high_level" {
            data["high_level_selected"] = true
            isHighLevel = true
        } else {
            data["low_level_selected"] = true
            isHighLevel = false
        }
        
        var accs = [Account]()
        let accountsRows = accounts.components(separatedBy: "\n")
        for accountsRow in accountsRows {
            let rowSplit = accountsRow.components(separatedBy: ",")
            if rowSplit.count == 2 {
                let username = rowSplit[0]
                let password = rowSplit[1]
                accs.append(Account(username: username, password: password, isHighLevel: isHighLevel, firstWarningTimestamp: nil, failedTimestamp: nil, failed: nil))
            }
        }
        
        if accs.count == 0 {
            data["show_error"] = true
            data["error"] = "Failed to parse accounts."
            return data
        } else {
            do {
                for acc in accs {
                    try acc.save(update: false)
                }
            } catch {
                data["show_error"] = true
                data["error"] = "Failed to save accounts."
                return data
            }
            response.redirect(path: "/dashboard/accounts")
            sessionDriver.save(session: request.session!)
            response.completed(status: .seeOther)
            throw CompletedEarly()
        }
    }
}
