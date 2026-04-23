package auth

import (
	"context"
	"errors"
	"fmt"

	"github.com/treeverse/lakefs/pkg/auth/model"
)

func UserByToken(ctx context.Context, authService Service, tokenString string) (*model.User, error) {
	claims, err := VerifyToken(authService.SecretStore().SharedSecret(), tokenString)
	if err != nil {
		return nil, fmt.Errorf("verify token: %w: %w", ErrAuthenticatingRequest, err)
	}

	username := claims.Subject
	userData, err := authService.GetUser(ctx, username)
	if err != nil {
		return nil, fmt.Errorf("get user %s (token %s): %w", username, claims.ID, err)
	}
	return userData, nil
}

func UserByAuth(ctx context.Context, authenticator Authenticator, authService Service, accessKey string, secretKey string) (*model.User, error) {
	user, _, err := UserByBasicCredentials(ctx, authenticator, authService, accessKey, secretKey)
	return user, err
}

// UserByBasicCredentials authenticates S3-style access key + secret and returns the user and whether the key is read-only.
func UserByBasicCredentials(ctx context.Context, authenticator Authenticator, authService Service, accessKey, secretKey string) (*model.User, bool, error) {
	username, err := authenticator.AuthenticateUser(ctx, accessKey, secretKey)
	if err != nil {
		if errors.Is(err, ErrNotFound) || errors.Is(err, ErrInvalidSecretAccessKey) {
			return nil, false, fmt.Errorf("%w (access key %s): %w", ErrAuthenticatingRequest, accessKey, err)
		}
		return nil, false, fmt.Errorf("authenticate access key %s: %w", accessKey, err)
	}
	cred, err := authService.GetCredentials(ctx, accessKey)
	readOnly := err == nil && cred != nil && cred.ReadOnly
	user, err := authService.GetUser(ctx, username)
	if err != nil {
		return nil, false, fmt.Errorf("get user %s: %w", username, err)
	}
	return user, readOnly, nil
}
