FROM golang:1.27-alpine AS build
WORKDIR /src
COPY . .
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /sidecar .

FROM scratch
COPY --from=build /sidecar /sidecar
ENTRYPOINT ["/sidecar"]
