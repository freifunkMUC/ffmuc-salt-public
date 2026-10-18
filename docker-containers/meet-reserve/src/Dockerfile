FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go index.html logo.png favicon.png ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /meet-reserve .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /meet-reserve /meet-reserve
USER nonroot
EXPOSE 8095
ENTRYPOINT ["/meet-reserve"]
