package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"
	"github.com/gorilla/sessions"
	"github.com/treeverse/lakefs/pkg/api/apigen"
	"github.com/treeverse/lakefs/pkg/auth"
	"github.com/treeverse/lakefs/pkg/auth/model"
	"github.com/treeverse/lakefs/pkg/logging"
)

// extractSecurityRequirements using Swagger returns an array of security requirements set for the request.
func extractSecurityRequirements(router routers.Router, r *http.Request) (openapi3.SecurityRequirements, error) {
	// Find route
	route, _, err := router.FindRoute(r)
	if err != nil {
		return nil, err
	}
	if route.Operation.Security == nil {
		return route.Spec.Security, nil
	}
	return *route.Operation.Security, nil
}

func GenericAuthMiddleware(logger logging.Logger, authenticator auth.Authenticator, authService auth.Service, oidcConfig *auth.OIDCConfig, cookieAuthConfig *auth.CookieAuthConfig) (func(next http.Handler) http.Handler, error) {
	swagger, err := apigen.GetSwagger()
	if err != nil {
		return nil, err
	}
	sessionStore := sessions.NewCookieStore(authService.SecretStore().SharedSecret())
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			user, credReadOnly, err := checkSecurityRequirements(r, swagger.Security, logger, authenticator, authService, sessionStore, oidcConfig, cookieAuthConfig)
			if err != nil {
				writeAuthError(w, r, err, http.StatusUnauthorized, ErrAuthenticatingRequest.Error())
				return
			}
			if user != nil {
				ctx := logging.AddFields(r.Context(), logging.Fields{logging.UserFieldKey: user.Username})
				ctx = auth.WithCredentialReadOnly(ctx, credReadOnly)
				r = r.WithContext(auth.WithUser(ctx, user))
			}
			next.ServeHTTP(w, r)
		})
	}, nil
}

func AuthMiddleware(logger logging.Logger, swagger *openapi3.T, authenticator auth.Authenticator, authService auth.Service, sessionStore sessions.Store, oidcConfig *auth.OIDCConfig, cookieAuthConfig *auth.CookieAuthConfig) func(next http.Handler) http.Handler {
	router, err := legacy.NewRouter(swagger)
	if err != nil {
		panic(err)
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// if request already authenticated
			if _, userNotFoundErr := auth.GetUser(r.Context()); userNotFoundErr == nil {
				next.ServeHTTP(w, r)
				return
			}
			securityRequirements, err := extractSecurityRequirements(router, r)
			if err != nil {
				writeAuthError(w, r, err, http.StatusBadRequest, err.Error())
				return
			}
			user, credReadOnly, err := checkSecurityRequirements(r, securityRequirements, logger, authenticator, authService, sessionStore, oidcConfig, cookieAuthConfig)
			if err != nil {
				writeAuthError(w, r, err, http.StatusUnauthorized, ErrAuthenticatingRequest.Error())
				return
			}
			if user != nil {
				ctx := logging.AddFields(r.Context(), logging.Fields{logging.UserFieldKey: user.Username})
				ctx = auth.WithCredentialReadOnly(ctx, credReadOnly)
				r = r.WithContext(auth.WithUser(ctx, user))
			}
			next.ServeHTTP(w, r)
		})
	}
}

// checkSecurityRequirements goes over the security requirements and checks the authentication.
// It returns the user information, whether the request authenticated with a read-only access key (basic auth),
// and an error if the security check was required.
// It will return nil user, false, and nil error in case of no security checks to match.
func checkSecurityRequirements(r *http.Request,
	securityRequirements openapi3.SecurityRequirements,
	logger logging.Logger,
	authenticator auth.Authenticator,
	authService auth.Service,
	sessionStore sessions.Store,
	oidcConfig *auth.OIDCConfig,
	cookieAuthConfig *auth.CookieAuthConfig,
) (*model.User, bool, error) {
	ctx := r.Context()
	logger = logger.WithContext(ctx)

	for _, securityRequirement := range securityRequirements {
		for provider := range securityRequirement {
			var (
				user         *model.User
				credentialRO bool
				err          error
			)

			switch provider {
			case "jwt_token":
				authHeaderValue := r.Header.Get("Authorization")
				if authHeaderValue == "" {
					continue
				}
				parts := strings.Fields(authHeaderValue)
				if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
					continue
				}
				user, err = auth.UserByToken(ctx, authService, parts[1])
			case "basic_auth":
				accessKey, secretKey, ok := r.BasicAuth()
				if !ok {
					continue
				}
				user, credentialRO, err = auth.UserByBasicCredentials(ctx, authenticator, authService, accessKey, secretKey)
			case "cookie_auth":
				internalAuthSession, _ := sessionStore.Get(r, auth.InternalAuthSessionName)
				token := ""
				if internalAuthSession != nil {
					token, _ = internalAuthSession.Values[auth.TokenSessionKeyName].(string)
				}
				if token == "" {
					continue
				}
				user, err = auth.UserByToken(ctx, authService, token)
			case "oidc_auth":
				oidcSession, getErr := sessionStore.Get(r, auth.OIDCAuthSessionName)
				if getErr != nil {
					return nil, false, getErr
				}
				user, err = auth.UserFromOIDCSession(ctx, logger, authService, oidcSession, oidcConfig)
			case "saml_auth":
				samlSession, getErr := sessionStore.Get(r, auth.SAMLAuthSessionName)
				if getErr != nil {
					return nil, false, getErr
				}
				user, err = auth.UserFromSAMLSession(ctx, logger, authService, samlSession, cookieAuthConfig)
			default:
				logger.WithField("provider", provider).Error("Authentication middleware unknown security requirement provider")
				return nil, false, auth.ErrAuthenticatingRequest
			}

			if err != nil {
				return nil, false, err
			}
			if user != nil {
				return user, credentialRO, nil
			}
		}
	}

	return nil, false, nil
}

// writeAuthError centralizes error handling logic and avoids duplication
func writeAuthError(w http.ResponseWriter, r *http.Request, err error, defaultStatus int, defaultMsg string) {
	logging.FromContext(r.Context()).WithError(err).Warn("authentication error")
	// Only internal server errors are returned to the client to allow retries.
	// Other errors are masked to avoid exposing sensitive information.
	if errors.Is(err, auth.ErrInternalServerError) {
		writeError(w, r, http.StatusInternalServerError, auth.ErrInternalServerError)
	} else {
		writeError(w, r, defaultStatus, defaultMsg)
	}
}
