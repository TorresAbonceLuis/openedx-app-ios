import Foundation
import AppAuth
import Core
import UIKit
import Swinject
import Alamofire

@MainActor
public final class LlaveMXAuthProvider {
    
    // mantener el flujo de autorización activo
    private static var currentAuthorizationFlow: OIDExternalUserAgentSession?
    
    public init() {}
    
    public func authorize(
        from controller: UIViewController,
        completion: @escaping (String?, Error?) -> Void
    ) {
        let config = Container.shared.resolve(ConfigProtocol.self)?.llaveMX
        
        // validar la configuración en YAML
        guard let clientID = config?.clientID,
              let redirectURI = config?.redirectURI,
              let redirectURL = URL(string: redirectURI) else {
            let error = NSError(
                domain: "LlaveMX",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Falta ClientID o RedirectURI en config.yaml"]
            )
            completion(nil, error)
            return
        }

        // urls para app
        let authURL = URL(string: "https://val-llave.infotec.mx/oauth.xhtml")!
        let tokenURL = URL(
            string: "https://val-api-llave.infotec.mx/ws/rest/apps/oauth/obtenerToken"
        )!

        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL
        )
        
        // crear solicitud con PKCE AppAuth lo hace automático
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            scopes: ["openid", "profile"],
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )

        // abrir Navegador Seguro y obtener solo el código (sin intercambiar por token)
        LlaveMXAuthProvider.currentAuthorizationFlow = OIDAuthorizationService.present(
            request,
            presenting: controller
        ) { authorizationResponse, error in
            
            if let error = error {
                print("Error LlaveMX: \(error.localizedDescription)")
                completion(nil, error)
                LlaveMXAuthProvider.currentAuthorizationFlow = nil
                return
            }
            
            guard let authCode = authorizationResponse?.authorizationCode,
                  let codeVerifier = request.codeVerifier else {
                let error = NSError(
                    domain: "LlaveMX",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No se recibió código de autorización"]
                )
                completion(nil, error)
                LlaveMXAuthProvider.currentAuthorizationFlow = nil
                return
            }
            
            // Intercambiar código por token usando JSON
            Task {
                do {
                    let token = try await self.exchangeCodeForToken(
                        code: authCode,
                        codeVerifier: codeVerifier,
                        redirectURI: redirectURI,
                        clientID: clientID
                    )
                    completion(token, nil)
                } catch {
                    print("Error intercambiando token: \(error.localizedDescription)")
                    completion(nil, error)
                }
                LlaveMXAuthProvider.currentAuthorizationFlow = nil
            }
        }
    }
    
    // Intercambio de código por token usando JSON
    private func exchangeCodeForToken(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String
    ) async throws -> String {
        let tokenURL = "https://val-api-llave.infotec.mx/ws/rest/apps/oauth/obtenerToken"
        
        // Parámetros según documentación de LlaveMX (camelCase)
        let parameters: [String: String] = [
            "grantType": "authorization_code",
            "code": code,
            "redirectUri": redirectURI,
            "clientId": clientID,
            "codeVerifier": codeVerifier
        ]
        
        print("=== Enviando parámetros a LlaveMX ===")
        print("URL: \(tokenURL)")
        print("Parámetros: \(parameters)")
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(
                tokenURL,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                headers: ["Content-Type": "application/json"]
            )
            .validate()
            .responseDecodable(of: TokenResponse.self) { response in
                switch response.result {
                case .success(let tokenResponse):
                    print("✅ Token recibido exitosamente")
                    continuation.resume(returning: tokenResponse.accessToken)
                case .failure(let error):
                    print("❌ Error de red: \(error)")
                    if let data = response.data, let errorString = String(data: data, encoding: .utf8) {
                        print("Respuesta del servidor: \(errorString)")
                    }
                    if let request = response.request {
                        print("Request: \(request)")
                        print("Headers: \(request.allHTTPHeaderFields ?? [:])")
                        if let body = request.httpBody {
                            print("Body: \(String(data: body, encoding: .utf8) ?? "no body")")
                        }
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // Estructura para decodificar la respuesta (camelCase como devuelve LlaveMX)
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: String
        let refreshToken: String
        let tokenType: String
    }
    
    // reanudar el flujo
    public static func resumeAuthorizationFlow(with url: URL) -> Bool {
        if let authorizationFlow = currentAuthorizationFlow,
           authorizationFlow.resumeExternalUserAgentFlow(with: url) {
            currentAuthorizationFlow = nil
            return true
        }
        return false
    }
}
